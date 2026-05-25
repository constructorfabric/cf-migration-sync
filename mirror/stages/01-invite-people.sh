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

# Members to exclude from invitations
EXCLUDE_LOGINS=("dfc-Acronis" "alexpitsikoulis" "gaidar")

STATE_FILE="$REPO_ROOT/state/people.yaml"

# ---------------------------------------------------------------------------
main() {
  check_dry_run "$@"
  preflight

  log "Stage 01 — invite-people starting"
  log "Source org: $SOURCE_ORG | Target org: $TARGET_ORG"

  state_init "$STATE_FILE" "01-invite-people"

  # ---- 1. Fetch all source org members -----------------------------------
  log "Fetching source org members..."
  local members
  members="$(gh_paginate ghsrc "orgs/$SOURCE_ORG/members")"
  local total_members
  total_members="$(echo "$members" | jq 'length')"
  log "Found $total_members members in $SOURCE_ORG"

  # ---- 2. Fetch pending invitations to target org ------------------------
  log "Fetching pending invitations to $TARGET_ORG..."
  local pending_invites
  pending_invites="$(gh api "orgs/$TARGET_ORG/invitations?per_page=100" 2>/dev/null || echo '[]')"
  local pending_logins
  pending_logins="$(echo "$pending_invites" | jq -r '.[].login // empty' | tr '[:upper:]' '[:lower:]')"

  # ---- 3. Process each member -------------------------------------------
  local processed=0
  local invited_count=0
  local skipped_count=0
  local already_member_count=0
  local failed_count=0

  while IFS= read -r member; do
    local login
    login="$(echo "$member" | jq -r '.login')"
    local login_lower
    login_lower="$(echo "$login" | tr '[:upper:]' '[:lower:]')"

    processed=$((processed + 1))
    if (( processed % 25 == 0 )); then
      log "Progress: $processed/$total_members processed..."
    fi

    # Check exclusion list
    local excluded=0
    for excl in "${EXCLUDE_LOGINS[@]}"; do
      if [[ "${login_lower}" == "$(echo "$excl" | tr '[:upper:]' '[:lower:]')" ]]; then
        excluded=1
        break
      fi
    done
    if [[ "$excluded" -eq 1 ]]; then
      log "Skipping excluded member: $login"
      _upsert_person "$login" "" "skipped" "" ""
      skipped_count=$((skipped_count + 1))
      continue
    fi

    # Check current state
    local current_status
    current_status="$(jq -r --arg login "$login" \
      '.items[] | select(.login == $login) | .status // empty' \
      "$STATE_FILE" 2>/dev/null || true)"

    if [[ "$current_status" == "accepted" ]]; then
      log "Skipping $login — already accepted"
      skipped_count=$((skipped_count + 1))
      continue
    fi

    if [[ "$current_status" == "invited" ]]; then
      log "Skipping $login — already invited (pending)"
      skipped_count=$((skipped_count + 1))
      continue
    fi

    # Check if already a member of target org
    local http_code
    http_code="$(gh api "orgs/$TARGET_ORG/members/$login" \
      -i 2>/dev/null | head -1 | awk '{print $2}' || echo "000")"

    if [[ "$http_code" == "204" ]]; then
      log "$login is already a member of $TARGET_ORG"
      # GitHub REST API does not expose the org-join date, so both timestamps are unknown.
      _upsert_person "$login" "" "accepted" "" ""
      already_member_count=$((already_member_count + 1))
      continue
    fi

    # Check if already in pending invitations
    if echo "$pending_logins" | grep -qx "$login_lower" 2>/dev/null; then
      log "$login already has a pending invitation"
      # Extract the actual invitation created_at from the pre-fetched pending list.
      local actual_invited_at
      actual_invited_at="$(echo "$pending_invites" | jq -r --arg l "$login_lower" \
        '.[] | select((.login // "" | ascii_downcase) == $l) | .created_at // empty' \
        | head -1)"
      _upsert_person "$login" "" "invited" "${actual_invited_at}" ""
      invited_count=$((invited_count + 1))
      continue
    fi

    # Fetch source user ID (needed for invitation API)
    local user_data
    user_data="$(ghsrc api "users/$login" 2>/dev/null || echo '{}')"
    local source_id
    source_id="$(echo "$user_data" | jq -r '.id // empty')"
    local role
    role="$(echo "$member" | jq -r '.role // "member"')"

    if [[ -z "$source_id" ]]; then
      warn "Could not fetch user ID for $login, skipping"
      _upsert_person "$login" "" "failed" "" ""
      failed_count=$((failed_count + 1))
      continue
    fi

    # Send invitation
    if dry_run_skip "gh api orgs/$TARGET_ORG/invitations -f invitee_id=$source_id -f role=direct_member"; then
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
        warn "Failed to invite $login"
        _upsert_person "$login" "$source_id" "failed" "" ""
        failed_count=$((failed_count + 1))
      else
        ok "Invited $login"
        # Use the created_at from the API response — the actual server-side timestamp.
        local actual_invited_at
        actual_invited_at="$(echo "$invite_result" | jq -r '.created_at // empty')"
        _upsert_person "$login" "$source_id" "invited" "${actual_invited_at}" ""
        invited_count=$((invited_count + 1))
      fi

      pause 0.3
    fi

  done < <(echo "$members" | jq -c '.[]')

  # ---- 4. Update stats ---------------------------------------------------
  state_update_stats "$STATE_FILE"

  log "Stage 01 complete — invited=$invited_count already_member=$already_member_count skipped=$skipped_count failed=$failed_count"

  # ---- 5. Commit state ---------------------------------------------------
  if [[ "$DRY_RUN" -eq 0 ]]; then
    commit_state "mirror: state after stage 01 (invite-people) [skip ci]"
  fi
}

# ---------------------------------------------------------------------------
# Upsert a person record in the state YAML
# _upsert_person <login> <source_id> <status> <invited_at> <accepted_at>
_upsert_person() {
  local login="$1"
  local source_id="$2"
  local status="$3"
  local invited_at="${4:-}"
  local accepted_at="${5:-}"
  local ts
  ts="$(now)"

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
