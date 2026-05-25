#!/usr/bin/env bash
# mirror/stages/09-mirror-teams.sh
# Mirror teams from source org to target org:
#   - Create teams (preserving parent-child hierarchy, parents first)
#   - Sync team members with their roles (member | maintainer)
#   - Sync team repository permissions
# State file: state/teams.yaml
#
# Depends on: stage 01 (members must exist in target), stage 02 (repos must exist)
#
# Usage:
#   SOURCE_ORG=cyberfabric TARGET_ORG=constructorfabric \
#   GH_TOKEN=xxx GH_TOKEN_SOURCE=xxx \
#   ./mirror/stages/09-mirror-teams.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

TARGET_ORG="${TARGET_ORG:-constructorfabric}"
STATE_FILE="$REPO_ROOT/state/teams.yaml"

# ---------------------------------------------------------------------------
main() {
  check_dry_run "$@"
  preflight

  log "Stage 09 — mirror-teams starting"

  state_init "$STATE_FILE" "09-mirror-teams"

  # ---- Load excluded teams from config ------------------------------------
  local excluded_teams
  excluded_teams="$(jq -r '.stage_09_mirror_teams.exclude_teams[] // empty' \
    "$MIRROR_CONFIG" 2>/dev/null || true)"
  if [[ -n "$excluded_teams" ]]; then
    log "Excluded teams: $(echo "$excluded_teams" | tr '\n' ' ')"
  fi

  # ---- 1. Fetch all source teams ------------------------------------------
  log "Fetching teams from $SOURCE_ORG..."
  local all_teams
  all_teams="$(gh_paginate ghsrc "orgs/$SOURCE_ORG/teams")"
  local total_teams
  total_teams="$(echo "$all_teams" | jq 'length')"
  log "Found $total_teams teams in $SOURCE_ORG"

  if [[ "$total_teams" -eq 0 ]]; then
    log "No teams to mirror."
    return 0
  fi

  # ---- 2. Pre-fetch existing target teams ---------------------------------
  log "Fetching existing teams in $TARGET_ORG..."
  local tgt_teams_json
  tgt_teams_json="$(gh_paginate gh "orgs/$TARGET_ORG/teams" 2>/dev/null || echo '[]')"

  # ---- 3. Create teams — multi-pass topological sort ----------------------
  # Parents must be created before children. We loop until all teams are
  # processed or no progress is made (which indicates an unresolvable cycle
  # or a missing parent — both are logged as warnings).
  log "Creating teams (multi-pass for parent-child ordering)..."
  local remaining_teams="$all_teams"
  local pass=0
  local prev_remaining=999
  declare -A created_slug_to_target_id  # source slug → target team id

  # Pre-populate from already-existing target teams
  while IFS= read -r tteam; do
    local tslug tid
    tslug="$(echo "$tteam" | jq -r '.slug')"
    tid="$(echo   "$tteam" | jq -r '.id')"
    created_slug_to_target_id["$tslug"]="$tid"
  done < <(echo "$tgt_teams_json" | jq -c '.[]' 2>/dev/null || true)

  while true; do
    local current_remaining
    current_remaining="$(echo "$remaining_teams" | jq 'length')"
    [[ "$current_remaining" -eq 0 ]] && break
    if [[ "$current_remaining" -eq "$prev_remaining" ]]; then
      warn "Could not make progress on remaining $current_remaining teams — possible missing parents or API errors"
      break
    fi
    prev_remaining=$current_remaining
    pass=$((pass + 1))
    log "  Team creation pass $pass ($current_remaining remaining)..."

    local still_remaining="[]"

    while IFS= read -r team; do
      local src_slug
      src_slug="$(echo "$team" | jq -r '.slug')"

      # Check exclusion
      if [[ -n "$excluded_teams" ]] && echo "$excluded_teams" | grep -qx "$src_slug" 2>/dev/null; then
        log "  Skipping excluded team: $src_slug"
        continue
      fi

      local parent_slug parent_target_id=""
      parent_slug="$(echo "$team" | jq -r '.parent.slug // empty' 2>/dev/null || true)"

      # If this team has a parent that hasn't been created in target yet, defer
      if [[ -n "$parent_slug" ]]; then
        parent_target_id="${created_slug_to_target_id[$parent_slug]:-}"
        if [[ -z "$parent_target_id" ]]; then
          still_remaining="$(echo "$still_remaining" | jq --argjson t "$team" '. + [$t]')"
          continue
        fi
      fi

      _create_or_update_team "$team" "$parent_target_id"
      local result_id="${_LAST_TEAM_ID:-}"
      if [[ -n "$result_id" ]]; then
        created_slug_to_target_id["$src_slug"]="$result_id"
      fi

    done < <(echo "$remaining_teams" | jq -c '.[]' 2>/dev/null || true)

    remaining_teams="$still_remaining"
  done

  # ---- 4. Sync members and repo permissions for every team ----------------
  log "Syncing team members and repo permissions..."
  while IFS= read -r team; do
    local src_slug
    src_slug="$(echo "$team" | jq -r '.slug')"

    if [[ -n "$excluded_teams" ]] && echo "$excluded_teams" | grep -qx "$src_slug" 2>/dev/null; then
      continue
    fi

    _sync_team_members   "$team"
    _sync_team_repos     "$team"
    pause 0.3
  done < <(echo "$all_teams" | jq -c '.[]' 2>/dev/null || true)

  # ---- 5. Update stats and commit -----------------------------------------
  state_update_stats "$STATE_FILE"

  local total synced failed
  total="$(jq '.stats.total'   "$STATE_FILE")"
  synced="$(jq '.stats.synced' "$STATE_FILE")"
  failed="$(jq '.stats.failed' "$STATE_FILE")"
  log "Stage 09 complete — total=$total synced=$synced failed=$failed"

  if [[ "$DRY_RUN" -eq 0 ]]; then
    commit_state "mirror: state after stage 09 (mirror-teams) [skip ci]"
  fi
}

# ---------------------------------------------------------------------------
# _LAST_TEAM_ID — set by _create_or_update_team for the caller to read
_LAST_TEAM_ID=""

_create_or_update_team() {
  local team="$1"
  local parent_target_id="${2:-}"  # empty for root teams
  _LAST_TEAM_ID=""

  local src_id src_slug src_name src_desc src_privacy
  src_id="$(echo      "$team" | jq -r '.id')"
  src_slug="$(echo    "$team" | jq -r '.slug')"
  src_name="$(echo    "$team" | jq -r '.name')"
  src_desc="$(echo    "$team" | jq -r '.description // ""')"
  src_privacy="$(echo "$team" | jq -r '.privacy // "secret"')"

  # Check if team already exists in target by slug
  local existing_tgt_id
  existing_tgt_id="$(gh api "orgs/$TARGET_ORG/teams/$src_slug" \
    2>/dev/null | jq -rs '.[0].id // empty' 2>/dev/null || true)"

  if [[ -n "$existing_tgt_id" ]]; then
    log "  Team '$src_slug' already exists (id=$existing_tgt_id)"
    _LAST_TEAM_ID="$existing_tgt_id"
    _upsert_team "$src_id" "$src_slug" "$existing_tgt_id" "$src_name" "mirrored"
    return 0
  fi

  if dry_run_skip "create team $src_slug in $TARGET_ORG (parent_id=${parent_target_id:-none})"; then
    _upsert_team "$src_id" "$src_slug" "" "$src_name" "mirrored"
    return 0
  fi

  # Build payload
  local payload
  payload="$(jq -n \
    --arg name    "$src_name" \
    --arg desc    "$src_desc" \
    --arg privacy "$src_privacy" \
    '{"name":$name,"description":$desc,"privacy":$privacy}')"

  if [[ -n "$parent_target_id" ]]; then
    payload="$(echo "$payload" | jq --argjson pid "$parent_target_id" '.parent_team_id = $pid')"
  fi

  local result
  result="$(gh api "orgs/$TARGET_ORG/teams" \
    --method POST \
    --input <(echo "$payload") \
    2>/dev/null || echo 'FAILED')"

  if [[ "$result" == "FAILED" ]]; then
    warn "  Failed to create team '$src_slug'"
    _upsert_team "$src_id" "$src_slug" "" "$src_name" "failed"
    return 1
  fi

  local tgt_id
  tgt_id="$(echo "$result" | jq -rs '.[0].id // empty' 2>/dev/null || true)"
  ok "  Created team '$src_slug' (id=$tgt_id)"
  _LAST_TEAM_ID="$tgt_id"
  _upsert_team "$src_id" "$src_slug" "$tgt_id" "$src_name" "mirrored"
}

# ---------------------------------------------------------------------------
_sync_team_members() {
  local team="$1"
  local src_slug
  src_slug="$(echo "$team" | jq -r '.slug')"

  log "  Syncing members for team '$src_slug'..."

  local members
  members="$(ghsrc api \
    "orgs/$SOURCE_ORG/teams/$src_slug/members?per_page=100&role=all" \
    --paginate 2>/dev/null | jq -s 'add // []' || echo '[]')"

  local member_count
  member_count="$(echo "$members" | jq 'length' 2>/dev/null || echo 0)"

  if [[ "$member_count" -eq 0 ]]; then
    log "  No members in team '$src_slug'"
    return 0
  fi

  local added=0 skipped=0 failed=0

  while IFS= read -r member; do
    local login role
    login="$(echo "$member" | jq -r '.login')"

    # Fetch member's role in this team (member vs maintainer)
    role="$(ghsrc api "orgs/$SOURCE_ORG/teams/$src_slug/memberships/$login" \
      2>/dev/null | jq -rs '.[0].role // "member"' 2>/dev/null || echo 'member')"

    if dry_run_skip "add $login (role=$role) to team $TARGET_ORG/$src_slug"; then
      added=$((added + 1))
      continue
    fi

    local result
    result="$(gh api "orgs/$TARGET_ORG/teams/$src_slug/memberships/$login" \
      --method PUT \
      -f role="$role" \
      2>/dev/null || echo 'FAILED')"

    if [[ "$result" == "FAILED" ]]; then
      warn "  Failed to add $login to team '$src_slug' (user may not be in target org yet)"
      failed=$((failed + 1))
    else
      added=$((added + 1))
    fi
    pause 0.2
  done < <(echo "$members" | jq -c '.[]' 2>/dev/null || true)

  log "  Team '$src_slug' members: added=$added skipped=$skipped failed=$failed"
}

# ---------------------------------------------------------------------------
_sync_team_repos() {
  local team="$1"
  local src_slug
  src_slug="$(echo "$team" | jq -r '.slug')"

  log "  Syncing repo permissions for team '$src_slug'..."

  local team_repos
  team_repos="$(ghsrc api \
    "orgs/$SOURCE_ORG/teams/$src_slug/repos?per_page=100" \
    --paginate 2>/dev/null | jq -s 'add // []' || echo '[]')"

  local repo_count
  repo_count="$(echo "$team_repos" | jq 'length' 2>/dev/null || echo 0)"

  if [[ "$repo_count" -eq 0 ]]; then
    return 0
  fi

  local synced=0 failed=0

  while IFS= read -r repo; do
    local repo_name permission
    repo_name="$(echo  "$repo" | jq -r '.name')"
    # role_name is the canonical permission level on team repos
    permission="$(echo "$repo" | jq -r '.role_name // .permissions |
      if type == "string" then . elif .admin then "admin"
      elif .maintain then "maintain" elif .push then "push"
      elif .triage then "triage" else "pull" end' \
      2>/dev/null || echo 'pull')"

    if dry_run_skip "set $permission on $TARGET_ORG/$repo_name for team $src_slug"; then
      synced=$((synced + 1))
      continue
    fi

    local result
    result="$(gh api "orgs/$TARGET_ORG/teams/$src_slug/repos/$TARGET_ORG/$repo_name" \
      --method PUT \
      -f permission="$permission" \
      2>/dev/null || echo 'FAILED')"

    if [[ "$result" == "FAILED" ]]; then
      warn "  Failed to set $permission on $repo_name for team '$src_slug'"
      failed=$((failed + 1))
    else
      synced=$((synced + 1))
    fi
    pause 0.2
  done < <(echo "$team_repos" | jq -c '.[]' 2>/dev/null || true)

  log "  Team '$src_slug' repos: synced=$synced failed=$failed"
}

# ---------------------------------------------------------------------------
_upsert_team() {
  local src_id="$1"
  local src_slug="$2"
  local tgt_id="${3:-}"
  local name="$4"
  local status="$5"
  local ts
  ts="$(now)"

  local record
  record="$(jq -n \
    --argjson src_id "${src_id:-null}" \
    --arg     slug   "$src_slug" \
    --argjson tgt_id "${tgt_id:-null}" \
    --arg     name   "$name" \
    --arg     status "$status" \
    --arg     ts     "$ts" \
    '{
      source_id:   $src_id,
      source_slug: $slug,
      target_id:   $tgt_id,
      name:        $name,
      status:      $status,
      mirrored_at: $ts
    }')"

  local tmp
  tmp="$(mktemp)"
  jq --arg slug "$src_slug" --argjson rec "$record" \
    'if (.items | map(select(.source_slug == $slug)) | length) > 0
     then .items = [.items[] | if .source_slug == $slug then $rec else . end]
     else .items += [$rec]
     end' \
    "$STATE_FILE" > "$tmp"
  mv "$tmp" "$STATE_FILE"
}

main "$@"
