#!/usr/bin/env bash
# mirror/stages/14-mirror-outside-collaborators.sh
# Mirror per-repository outside collaborators from source to target.
#
# Outside collaborators are GitHub users with direct repository access who are
# NOT members of the org.  They are different from team-based repo access.
#
# This stage is gated by invite_members in mirror/config.json:
#   false — skipped entirely (collaborators can't be added to a repo if they
#           haven't been invited to the platform yet)
#   true  — collaborators are added with their original permission level
#
# Permission mapping:
#   Source API returns "permission" as one of: read|triage|write|maintain|admin
#   These map directly to the PUT /repos/.../collaborators/{login} permission field.
#
# Idempotency: PUT /repos/.../collaborators/{login} is safe to call repeatedly —
#   GitHub treats it as an upsert.  State file tracks status per (repo, login).
#
# State file: state/outside-collaborators/<repo-name>.yaml
#
# Usage:
#   SOURCE_ORG=cyberfabric TARGET_ORG=constructorfabric \
#   GH_TOKEN=xxx GH_TOKEN_SOURCE=xxx \
#   ./mirror/stages/14-mirror-outside-collaborators.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

TARGET_ORG="${TARGET_ORG:-constructorfabric}"
STATE_DIR="$REPO_ROOT/state/outside-collaborators"

# ---------------------------------------------------------------------------
main() {
  check_dry_run "$@"
  preflight

  log "Stage 14 — mirror-outside-collaborators starting"

  # ---- Guard: backup mode ------------------------------------------------
  # Adding collaborators requires them to have GitHub accounts and (for private
  # repos) accept an invitation.  In backup mode no one is being added to the
  # target org, so this stage would fail silently for private repos.
  if [[ "$INVITE_MEMBERS" -eq 0 ]]; then
    log "invite_members=false — stage 14 skipped (outside collaborator access requires active migration mode)"
    log "Set invite_members=true in mirror/config.json and re-run this stage to mirror collaborators"
    return 0
  fi

  mkdir -p "$STATE_DIR"

  log "Fetching source repos from $SOURCE_ORG..."
  local repos
  repos="$(gh_paginate ghsrc "orgs/$SOURCE_ORG/repos")"
  local total_repos
  total_repos="$(echo "$repos" | jq 'length')"
  log "Found $total_repos repos"

  local excluded_repos
  excluded_repos="$(jq -r '.stage_14_mirror_outside_collaborators.exclude_repos[] // empty' \
    "$MIRROR_CONFIG" 2>/dev/null || true)"

  # Load excluded logins (same list as stage 01 — NEVER add these users anywhere)
  local excluded_logins
  excluded_logins="$(jq -r '.stage_01_invite_people.exclude_logins[] // empty' \
    "$MIRROR_CONFIG" 2>/dev/null || true)"

  local repo_idx=0

  while IFS= read -r repo; do
    local repo_name
    repo_name="$(echo "$repo" | jq -r '.name')"
    repo_idx=$((repo_idx + 1))

    if [[ -n "$excluded_repos" ]] && echo "$excluded_repos" | grep -qx "$repo_name" 2>/dev/null; then
      log "[$repo_idx/$total_repos] Skipping excluded repo: $repo_name"
      continue
    fi

    # Fetch outside collaborators for this repo
    local collabs
    collabs="$(ghsrc api \
      "repos/$SOURCE_ORG/$repo_name/collaborators?affiliation=outside&per_page=100" \
      --paginate 2>/dev/null | jq -s 'add // []' || echo '[]')"

    local collab_count
    collab_count="$(echo "$collabs" | jq 'length' 2>/dev/null || echo 0)"

    if [[ "$collab_count" -eq 0 ]]; then
      continue
    fi

    log "[$repo_idx/$total_repos] $repo_name: $collab_count outside collaborators"

    local state_file="$STATE_DIR/$repo_name.yaml"
    state_init "$state_file" "14-mirror-outside-collaborators"

    while IFS= read -r collab; do
      local login login_lower permission
      login="$(echo "$collab" | jq -r '.login')"
      login_lower="$(echo "$login" | tr '[:upper:]' '[:lower:]')"

      # ---- CIRCUIT-BREAKER: blocked users --------------------------------
      if [[ "$login_lower" == "dfc-acronis" ]]; then
        warn "CIRCUIT-BREAKER: collaborator dfc-Acronis BLOCKED for $repo_name"
        continue
      fi

      # Check exclude list
      if [[ -n "$excluded_logins" ]] && echo "$excluded_logins" | \
          grep -qi "^${login}$" 2>/dev/null; then
        log "  Skipping excluded collaborator: $login on $repo_name"
        _upsert_collaborator "$state_file" "$repo_name" "$login" "" "skipped"
        continue
      fi

      # Fetch actual permission level for this collaborator
      # GET /collaborators returns .permissions object; extract highest grant
      permission="$(echo "$collab" | jq -r '
        .role_name //
        (.permissions |
          if .admin    then "admin"
          elif .maintain then "maintain"
          elif .push   then "write"
          elif .triage then "triage"
          else "read"
          end)' 2>/dev/null || echo 'read')"

      # Check idempotency via state
      local already_status
      already_status="$(jq -r --arg l "$login" \
        '.items[] | select(.login == $l) | .status // empty' \
        "$state_file" 2>/dev/null | head -1 || true)"
      if [[ "$already_status" == "synced" ]]; then
        continue
      fi

      if dry_run_skip "add collaborator $login ($permission) to $TARGET_ORG/$repo_name"; then
        _upsert_collaborator "$state_file" "$repo_name" "$login" "$permission" "synced"
        continue
      fi

      local result
      result="$(gh api "repos/$TARGET_ORG/$repo_name/collaborators/$login" \
        --method PUT \
        -f permission="$permission" \
        2>/dev/null || echo 'FAILED')"

      if [[ "$result" == "FAILED" ]]; then
        warn "  Failed to add $login ($permission) to $TARGET_ORG/$repo_name"
        _upsert_collaborator "$state_file" "$repo_name" "$login" "$permission" "failed"
      else
        ok "  Added $login ($permission) to $TARGET_ORG/$repo_name"
        _upsert_collaborator "$state_file" "$repo_name" "$login" "$permission" "synced"
      fi
      pause 0.3

    done < <(echo "$collabs" | jq -c '.[]' 2>/dev/null || true)

    state_update_stats "$state_file"
    pause 0.5
  done < <(echo "$repos" | jq -c '.[]')

  log "Stage 14 complete"

  if [[ "$DRY_RUN" -eq 0 ]]; then
    commit_state "mirror: state after stage 14 (mirror-outside-collaborators) [skip ci]"
  fi
}

# ---------------------------------------------------------------------------
_upsert_collaborator() {
  local state_file="$1"
  local repo_name="$2"
  local login="$3"
  local permission="$4"
  local status="$5"
  local ts
  ts="$(now)"

  local record
  record="$(jq -n \
    --arg repo       "$repo_name" \
    --arg login      "$login" \
    --arg permission "$permission" \
    --arg status     "$status" \
    --arg ts         "$ts" \
    '{"repo":$repo,"login":$login,"permission":$permission,"status":$status,"synced_at":$ts}')"

  local tmp; tmp="$(mktemp)"
  jq --arg login "$login" --argjson rec "$record" \
    'if (.items | map(select(.login == $login)) | length) > 0
     then .items = [.items[] | if .login == $login then $rec else . end]
     else .items += [$rec]
     end' "$state_file" > "$tmp"
  mv "$tmp" "$state_file"
}

main "$@"
