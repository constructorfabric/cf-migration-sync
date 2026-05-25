#!/usr/bin/env bash
# mirror/stages/07-assign-issues.sh
# Apply assignees to previously mirrored issues.
# Reads state/issues/<repo>.yaml — processes items where
#   assignees_status == "pending" AND assignees array is non-empty.
#
# Note: GitHub REST API has no "suppress notification" flag.
# Assignees will receive normal GitHub notifications when assigned.
#
# Usage:
#   SOURCE_ORG=cyberfabric TARGET_ORG=constructorfabric \
#   GH_TOKEN=xxx GH_TOKEN_SOURCE=xxx \
#   ./mirror/stages/07-assign-issues.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

TARGET_ORG="${TARGET_ORG:-constructorfabric}"
STATE_DIR="$REPO_ROOT/state/issues"

# ---------------------------------------------------------------------------
main() {
  check_dry_run "$@"
  preflight

  log "Stage 07 — assign-issues starting"

  # Load excluded logins (same list as stage 01 and stage 09)
  local excluded_logins
  excluded_logins="$(jq -r '.stage_01_invite_people.exclude_logins[] // empty' \
    "$MIRROR_CONFIG" 2>/dev/null || true)"
  if [[ -n "$excluded_logins" ]]; then
    log "Excluded logins: $(echo "$excluded_logins" | tr '\n' ' ')"
  fi

  # ---- Guard: backup mode -------------------------------------------------
  # Assigning issues requires the assignee to be an org member.
  # If invite_members=false, members have not been invited, so assignments
  # would fail silently (GitHub API ignores non-member logins in assignees).
  # Skip the entire stage to avoid noise in state files.
  if [[ "$INVITE_MEMBERS" -eq 0 ]]; then
    log "invite_members=false — stage 07 skipped (members not in target org)"
    log "Issue assignees will be applied when invite_members=true and stage 07 is re-run"
    return 0
  fi

  if [[ ! -d "$STATE_DIR" ]]; then
    warn "No issues state directory found at $STATE_DIR, nothing to do"
    exit 0
  fi

  local total_applied=0
  local total_skipped=0
  local total_failed=0

  # Iterate over all repo state files
  for state_file in "$STATE_DIR"/*.yaml; do
    [[ -f "$state_file" ]] || continue

    local repo_name
    repo_name="$(basename "$state_file" .yaml)"

    log "Processing assignees for $repo_name..."

    # Find items needing assignees applied
    local pending_items
    pending_items="$(jq -c \
      '[.items[] | select(.assignees_status == "pending" and (.assignees | length) > 0)]' \
      "$state_file" 2>/dev/null || echo '[]')"

    local pending_count
    pending_count="$(echo "$pending_items" | jq 'length')"

    if [[ "$pending_count" -eq 0 ]]; then
      log "  No pending assignees for $repo_name"
      continue
    fi

    log "  Found $pending_count issues with pending assignees in $repo_name"

    local processed=0

    while IFS= read -r item; do
      local src_number
      src_number="$(echo "$item" | jq -r '.source_number')"
      local tgt_number
      tgt_number="$(echo "$item" | jq -r '.target_number')"
      local assignees
      assignees="$(echo "$item" | jq -r '.assignees')"

      # ---- Filter excluded / blocked assignees ----------------------------
      # CIRCUIT-BREAKER: dfc-Acronis — hard block, unconditional
      local filtered_assignees
      filtered_assignees="$(echo "$assignees" | \
        jq '[.[] | select(ascii_downcase != "dfc-acronis")]')"
      if [[ "$(echo "$filtered_assignees" | jq 'length')" -lt \
            "$(echo "$assignees"          | jq 'length')" ]]; then
        warn "  CIRCUIT-BREAKER: dfc-Acronis BLOCKED from assignees on $repo_name#$src_number"
      fi

      # Config-excluded logins (stage_01_invite_people.exclude_logins)
      if [[ -n "$excluded_logins" ]]; then
        local excl_json
        excl_json="$(echo "$excluded_logins" | jq -R . | jq -s '[.[] | ascii_downcase]')"
        filtered_assignees="$(echo "$filtered_assignees" | \
          jq --argjson excl "$excl_json" \
          '[.[] | select((ascii_downcase) as $l | ($excl | map(select(. == $l)) | length) == 0)]')"
      fi

      # If nothing remains after filtering, mark applied and move on
      if [[ "$(echo "$filtered_assignees" | jq 'length')" -eq 0 ]]; then
        log "  All assignees excluded for $repo_name#$tgt_number — marking applied (no-op)"
        _update_assignees_status "$state_file" "$src_number" "applied" "$(now)"
        total_applied=$((total_applied + 1))
        continue
      fi

      processed=$((processed + 1))
      if (( processed % 25 == 0 )); then
        log "  Progress: $processed/$pending_count..."
      fi

      if [[ "$tgt_number" == "null" || -z "$tgt_number" ]]; then
        warn "  Issue #$src_number has no target number, skipping assignees"
        _update_assignees_status "$state_file" "$src_number" "failed" ""
        total_failed=$((total_failed + 1))
        continue
      fi

      if dry_run_skip "assign $assignees to $TARGET_ORG/$repo_name#$tgt_number"; then
        total_applied=$((total_applied + 1))
        continue
      fi

      log "  Assigning $assignees to $TARGET_ORG/$repo_name#$tgt_number (source #$src_number)..."

      # Try to apply all assignees (filtered list — excluded logins already removed)
      local payload
      payload="$(jq -n --argjson a "$filtered_assignees" '{"assignees":$a}')"

      local result
      result="$(gh api "repos/$TARGET_ORG/$repo_name/issues/$tgt_number/assignees" \
        --method POST \
        --input <(echo "$payload") \
        2>/dev/null || echo 'FAILED')"

      if [[ "$result" == "FAILED" ]]; then
        warn "  Failed to assign all assignees to $TARGET_ORG/$repo_name#$tgt_number, trying one by one..."

        # Try each assignee individually, skip invalid ones
        local applied_any=0
        local applied_list="[]"

        while IFS= read -r login; do
          # Defence-in-depth: circuit-breaker + excluded logins (filtered_assignees
          # already removes these, but guard here too in case of future refactors)
          if [[ "$(echo "$login" | tr '[:upper:]' '[:lower:]')" == "dfc-acronis" ]]; then
            warn "  CIRCUIT-BREAKER: dfc-Acronis BLOCKED (individual path) on $repo_name#$tgt_number"
            continue
          fi
          if [[ -n "$excluded_logins" ]] && echo "$excluded_logins" | \
              grep -qi "^${login}$" 2>/dev/null; then
            log "  Skipping excluded assignee: $login for $repo_name#$tgt_number"
            continue
          fi

          local single_payload
          single_payload="$(jq -n --arg l "$login" '{"assignees":[$l]}')"

          local single_result
          single_result="$(gh api "repos/$TARGET_ORG/$repo_name/issues/$tgt_number/assignees" \
            --method POST \
            --input <(echo "$single_payload") \
            2>/dev/null || echo 'FAILED')"

          if [[ "$single_result" != "FAILED" ]]; then
            applied_any=1
            applied_list="$(echo "$applied_list" | jq --arg l "$login" '. + [$l]')"
            ok "  Applied assignee $login to #$tgt_number"
          else
            warn "  Skipped invalid assignee: $login for $TARGET_ORG/$repo_name#$tgt_number"
          fi

          pause 0.3
        done < <(echo "$filtered_assignees" | jq -r '.[]')

        if [[ "$applied_any" -eq 1 ]]; then
          _update_assignees_status "$state_file" "$src_number" "applied" "$(now)"
          total_applied=$((total_applied + 1))
        else
          _update_assignees_status "$state_file" "$src_number" "failed" ""
          total_failed=$((total_failed + 1))
        fi
      else
        ok "  Applied assignees $assignees to $TARGET_ORG/$repo_name#$tgt_number"
        _update_assignees_status "$state_file" "$src_number" "applied" "$(now)"
        total_applied=$((total_applied + 1))
      fi

      pause 0.3

    done < <(echo "$pending_items" | jq -c '.[]')

    log "  Completed $repo_name: applied=$processed"
  done

  log "Stage 07 complete — applied=$total_applied skipped=$total_skipped failed=$total_failed"

  if [[ "$DRY_RUN" -eq 0 ]]; then
    commit_state "mirror: state after stage 07 (assign-issues) [skip ci]"
  fi
}

# ---------------------------------------------------------------------------
_update_assignees_status() {
  local state_file="$1"
  local src_number="$2"
  local new_status="$3"
  local applied_at="${4:-}"

  local tmp
  tmp="$(mktemp)"
  jq --argjson sn "$src_number" \
     --arg st "$new_status" \
     --arg at "${applied_at:-}" \
    '.items = [.items[] |
      if .source_number == $sn
      then .assignees_status = $st |
           if $at != "" then .assignees_applied_at = $at else . end
      else .
      end
    ]' \
    "$state_file" > "$tmp"
  mv "$tmp" "$state_file"
}

main "$@"
