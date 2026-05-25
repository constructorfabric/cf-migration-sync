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

      # Try to apply all assignees
      local payload
      payload="$(jq -n --argjson a "$assignees" '{"assignees":$a}')"

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
        done < <(echo "$assignees" | jq -r '.[]')

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
