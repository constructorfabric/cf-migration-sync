#!/usr/bin/env bash
# mirror/stages/01-invite-people.sh
# Invite all source org members to the target org.
# State file: state/people.yaml (JSON stored as .yaml)
#
# Usage:
#   SOURCE_ORG=cyberfabric TARGET_ORG=constructorfabric \
#   GH_TOKEN=xxx GH_TOKEN_SOURCE=xxx \
#   ./mirror/stages/01-invite-people.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

TARGET_ORG="${TARGET_ORG:-constructorfabric}"

# Populated from config in main() — do not edit here; edit mirror/config.json instead.
EXCLUDE_LOGINS=()

STATE_FILE="$REPO_ROOT/state/people.yaml"

# ---------------------------------------------------------------------------
main() {
  check_dry_run "$@"
  preflight

  log "Stage 01 — invite-people starting"
  log "Source org: $SOURCE_ORG | Target org: $TARGET_ORG"

  # ---- Guard: backup mode -------------------------------------------------
  # invite_members=false means this is a read-only mirror (backup/DR standby).
  # No invitations are sent.  All other stages run normally.
  # To switch to active DR mode: set invite_members=true in mirror/config.json
  # and re-run stages 01, 07, and 09.
  if [[ "$INVITE_MEMBERS" -eq 0 ]]; then
    log "invite_members=false — stage 01 skipped (backup/read-only mirror mode)"
    log "To invite members set invite_members=true in mirror/config.json"
    return 0
  fi

  # ---- Load exclusion list from config ------------------------------------
  while IFS= read -r _login; do
    [[ -n "$_login" ]] && EXCLUDE_LOGINS+=("$_login")
  done < <(jq -r '.stage_01_invite_people.exclude_logins[]' "$MIRROR_CONFIG" 2>/dev/null || true)
  log "Exclude list (${#EXCLUDE_LOGINS[@]} logins): ${EXCLUDE_LOGINS[*]:-none}"

  state_init "$STATE_FILE" "01-invite-people"

  # ---- 1. Fetch all source org members -----------------------------------
  log "Fetching source org members..."
  local members
  members="$(gh_paginate ghsrc "orgs/$SOURCE_ORG/members")"
  local total_members
  total_members="$(echo "$members" | jq 'length')"
  log "Found $total_members members in $SOURCE_ORG"

  # ---- 2. Pre-fetch current target org members --------------------------------
  # Single paginated call replaces N per-user HTTP checks and enables
  # "invited → accepted" state refresh on re-runs (see branch C below).
  log "Fetching current members of $TARGET_ORG..."
  local target_members_lower
  target_members_lower="$(gh api "orgs/$TARGET_ORG/members?per_page=100" \
    --paginate --jq '.[].login' 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
  local target_member_count
  target_member_count="$(echo "$target_members_lower" | grep -c . || true)"
  log "Found $target_member_count existing members in $TARGET_ORG"

  # ---- 3. Fetch pending invitations to target org -------------------------
  log "Fetching pending invitations to $TARGET_ORG..."
  local pending_invites
  pending_invites="$(gh api "orgs/$TARGET_ORG/invitations?per_page=100" 2>/dev/null || echo '[]')"
  local pending_logins
  pending_logins="$(echo "$pending_invites" | jq -r '.[].login // empty' | tr '[:upper:]' '[:lower:]')"

  # ---- 4. Process each member ---------------------------------------------
  local processed=0
  local invited_count=0
  local skipped_count=0
  local already_member_count=0
  local failed_count=0

  while IFS= read -r member; do
    # Bind all fields that appear in _upsert_person BEFORE any branch runs.
    # RCA: late-binding caused null source_id for already-member and pending-invited users
    # because source_id was previously only fetched in the "send invitation" branch.
    local login login_lower source_id
    login="$(echo "$member" | jq -r '.login')"
    login_lower="$(echo "$login" | tr '[:upper:]' '[:lower:]')"
    source_id="$(echo "$member" | jq -r '.id | tostring')"  # .id from members list = GitHub numeric user ID

    processed=$((processed + 1))
    if (( processed % 25 == 0 )); then
      log "Progress: $processed/$total_members processed..."
    fi

    # Branch A: exclusion list (local, no API call)
    local excluded=0
    for excl in "${EXCLUDE_LOGINS[@]}"; do
      if [[ "${login_lower}" == "$(echo "$excl" | tr '[:upper:]' '[:lower:]')" ]]; then
        excluded=1
        break
      fi
    done
    if [[ "$excluded" -eq 1 ]]; then
      log "Skipping excluded member: $login"
      _upsert_person "$login" "$source_id" "skipped" "" ""
      skipped_count=$((skipped_count + 1))
      continue
    fi

    # Branch B: state file "accepted" — fully done, skip with no API call
    local current_status
    current_status="$(jq -r --arg login "$login" \
      '.items[] | select(.login == $login) | .status // empty' \
      "$STATE_FILE" 2>/dev/null || true)"

    if [[ "$current_status" == "accepted" ]]; then
      skipped_count=$((skipped_count + 1))
      continue
    fi

    # Branch C: pre-fetched membership check — placed BEFORE the state "invited" check.
    # RCA: previously the "invited" skip fired first, so users who accepted after the
    # last run were permanently stuck at status=invited in the state file.
    if echo "$target_members_lower" | grep -qx "$login_lower" 2>/dev/null; then
      if [[ "$current_status" == "invited" ]]; then
        log "$login — invitation accepted (refreshing state from invited → accepted)"
      else
        log "$login is already a member of $TARGET_ORG"
      fi
      _upsert_person "$login" "$source_id" "accepted" "" ""
      already_member_count=$((already_member_count + 1))
      continue
    fi

    # Branch D: state file "invited" and not yet a member — still pending, skip
    if [[ "$current_status" == "invited" ]]; then
      log "Skipping $login — invitation still pending"
      skipped_count=$((skipped_count + 1))
      continue
    fi

    # Branch E: found in pending invitations list but not in state file yet
    if echo "$pending_logins" | grep -qx "$login_lower" 2>/dev/null; then
      log "$login already has a pending invitation"
      local actual_invited_at
      actual_invited_at="$(echo "$pending_invites" | jq -r --arg l "$login_lower" \
        '.[] | select((.login // "" | ascii_downcase) == $l) | .created_at // empty' \
        | head -1)"
      _upsert_person "$login" "$source_id" "invited" "${actual_invited_at}" ""
      invited_count=$((invited_count + 1))
      continue
    fi

    # Branch F: send new invitation
    # source_id is already bound from member data — no extra ghsrc API call needed.
    if [[ -z "$source_id" || "$source_id" == "null" ]]; then
      warn "Could not determine user ID for $login, skipping"
      _upsert_person "$login" "" "failed" "" ""
      failed_count=$((failed_count + 1))
      continue
    fi

    # ---- CIRCUIT-BREAKER: hard block — fires unconditionally --------------
    # dfc-Acronis must NEVER receive an invitation under any circumstances.
    # This check is intentionally hardcoded and independent of the exclude_logins
    # config so it cannot be bypassed by an accidental config edit.
    # No state is written here so a misconfigured exclude list stays visible
    # in logs on every subsequent run until config.json is corrected.
    if [[ "$(echo "$login" | tr '[:upper:]' '[:lower:]')" == "dfc-acronis" ]]; then
      warn "CIRCUIT-BREAKER: invitation to dfc-Acronis BLOCKED (login=$login id=$source_id) — this account must never be invited; verify exclude_logins in config.json"
      skipped_count=$((skipped_count + 1))
      continue
    fi

    if dry_run_skip "gh api orgs/$TARGET_ORG/invitations -F invitee_id=$source_id -f role=direct_member"; then
      _upsert_person "$login" "$source_id" "invited" "$(now)" ""
      invited_count=$((invited_count + 1))
    else
      log "Inviting $login (id=$source_id) to $TARGET_ORG..."
      local invite_result
      invite_result="$(gh api "orgs/$TARGET_ORG/invitations" \
        --method POST \
        -F invitee_id="$source_id" \
        -f role="direct_member" \
        2>/dev/null || echo 'FAILED')"

      if [[ "$invite_result" == "FAILED" ]]; then
        # Race condition check: did they accept between the pre-fetch and the invite POST?
        local recheck_code
        recheck_code="$(gh api "orgs/$TARGET_ORG/members/$login" \
          -i 2>/dev/null | head -1 | awk '{print $2}' || echo "000")"
        if [[ "$recheck_code" == "204" ]]; then
          warn "$login — invitation blocked: they joined during this run (race condition, all OK)"
          _upsert_person "$login" "$source_id" "accepted" "" ""
          already_member_count=$((already_member_count + 1))
        else
          warn "Failed to invite $login"
          _upsert_person "$login" "$source_id" "failed" "" ""
          failed_count=$((failed_count + 1))
        fi
      else
        ok "Invited $login"
        # Use created_at from the API response body.
        # -rs slurps all input (guards against extra lines gh may append on some runners).
        local actual_invited_at
        actual_invited_at="$(echo "$invite_result" | jq -rs '.[0].created_at // empty' 2>/dev/null || true)"
        _upsert_person "$login" "$source_id" "invited" "${actual_invited_at}" ""
        invited_count=$((invited_count + 1))
      fi

      pause 0.3
    fi

  done < <(echo "$members" | jq -c '.[]')

  # ---- 5. Update stats ---------------------------------------------------
  state_update_stats "$STATE_FILE"

  log "Stage 01 complete — invited=$invited_count already_member=$already_member_count skipped=$skipped_count failed=$failed_count"

  # ---- 6. Commit state ---------------------------------------------------
  if [[ "$DRY_RUN" -eq 0 ]]; then
    commit_state "mirror: state after stage 01 (invite-people) [skip ci]"
  fi
}

# ---------------------------------------------------------------------------
# Person lifecycle state machine
#
# States and their classification:
#   skipped  — TERMINAL: excluded user, never invite
#   accepted — TERMINAL: full org member, never re-invite
#   failed   — TERMINAL (this run): could not invite, will retry next run
#   invited  — TRANSIENT: invitation sent but not yet accepted
#              → must run live membership check before skipping on re-runs
#              → advances to accepted when member check returns true
#
# Valid transitions:
#   (new)  → skipped  (exclusion list)
#   (new)  → invited  (invitation sent)
#   (new)  → failed   (invitation API error)
#   (new)  → accepted (already a member at time of check)
#   invited → accepted (accepted between runs — detected by live check in branch C)
#   failed  → invited  (retry succeeds on next run)
#
# ---------------------------------------------------------------------------
# Upsert a person record in the state YAML
# _upsert_person <login> <source_id> <status> <invited_at> <accepted_at>
#
# Precondition contract:
#   - login:     must be non-empty
#   - source_id: must be non-empty and numeric (GitHub user ID)
#                empty is only permitted for status=skipped (excluded users have no need for it)
#   - status:    must be one of: skipped | invited | accepted | failed
#
# Violations are logged as warnings so bugs surface immediately in CI logs
# rather than silently persisting null/incomplete state records.
_upsert_person() {
  local login="$1"
  local source_id="$2"
  local status="$3"
  local invited_at="${4:-}"
  local accepted_at="${5:-}"
  local ts
  ts="$(now)"

  # ---- Precondition validation ----
  if [[ -z "$login" ]]; then
    err "_upsert_person: login is empty — skipping write (caller bug)"
    return 1
  fi
  if [[ "$status" != "skipped" && ( -z "$source_id" || "$source_id" == "null" ) ]]; then
    warn "_upsert_person: source_id is empty for $login (status=$status) — record will be incomplete; check caller"
  fi
  case "$status" in
    skipped|invited|accepted|failed) ;;
    *) warn "_upsert_person: unexpected status '$status' for $login — check state machine" ;;
  esac

  # ---- Timestamp handling ----
  # GitHub REST API does not expose org-join date or original invitation timestamp
  # for users who are already members (invitation record is deleted on acceptance).
  # What we CAN do:
  #   invited_at:  preserve the value already in the state file when transitioning
  #                invited → accepted, so the send-time recorded in a prior run is
  #                not overwritten by null.
  #   accepted_at: record the detection time (when this script confirmed membership).
  #                Not the exact moment they clicked Accept, but more useful than null.
  if [[ "$status" == "accepted" ]]; then
    # Preserve invited_at from existing state record if the caller didn't supply one
    if [[ -z "$invited_at" ]]; then
      invited_at="$(jq -r --arg login "$login" \
        '.items[] | select(.login == $login) | .invited_at // empty' \
        "$STATE_FILE" 2>/dev/null || true)"
    fi
    # Record detection time as accepted_at if not supplied
    if [[ -z "$accepted_at" ]]; then
      accepted_at="$(now)"
    fi
  fi

  # Build the record
  local record
  record="$(jq -n \
    --arg login       "$login" \
    --argjson sid     "${source_id:-null}" \
    --arg status      "$status" \
    --arg invited_at  "${invited_at:-}" \
    --arg accepted_at "${accepted_at:-}" \
    '{
      login:       $login,
      source_id:   $sid,
      role:        "member",
      status:      $status,
      invited_at:  (if $invited_at == "" then null else $invited_at end),
      accepted_at: (if $accepted_at == "" then null else $accepted_at end)
    }')"

  # Upsert into items array
  local tmp
  tmp="$(mktemp)"
  jq --arg login "$login" \
     --argjson rec "$record" \
    'if (.items | map(.login) | index($login)) != null
     then .items = [.items[] | if .login == $login then $rec else . end]
     else .items += [$rec]
     end' \
    "$STATE_FILE" > "$tmp"
  mv "$tmp" "$STATE_FILE"
}

main "$@"
