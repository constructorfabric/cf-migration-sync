#!/usr/bin/env bash
# mirror/stages/10-mirror-teams.sh
# Mirror teams from source org to target org:
#   - Create teams (preserving parent-child hierarchy, parents first)
#   - Sync team members with their roles (member | maintainer)
#   - Sync team repository permissions
# State file: state/teams.yaml
#
# Depends on: stage 01 (members must exist in target), stage 02 (repos must exist)
#
# Modes (MIRROR_MODE):
#   full   — fetch source teams (+members+repos) and apply to target (default).
#   export — fetch source teams (+members+repos) into a snapshot in state
#            (.source_snapshot). NEVER contacts the target org.
#   import — read the snapshot from state and create teams / sync members+repos
#            in the target. NEVER contacts the source org.
#
# The source reads (teams list, per-team members with roles, per-team repos) are
# centralised into _build_teams_snapshot; the apply helpers take their source
# data as arguments so full and import share identical apply code.
#
# Usage:
#   SOURCE_ORG=cyberfabric TARGET_ORG=constructorfabric \
#   GH_TOKEN=xxx GH_TOKEN_SOURCE=xxx \
#   MIRROR_MODE=full|export|import \
#   ./mirror/stages/10-mirror-teams.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

TARGET_ORG="${TARGET_ORG:-constructorfabric}"
STATE_FILE="$REPO_ROOT/state/teams.yaml"

# ---------------------------------------------------------------------------
# _build_teams_snapshot — fetch all source teams plus, for each team, its
# members (with role) and repo permissions. Emits a snapshot JSON on stdout:
#   { teams: [ <raw team> , ... ],
#     members: { "<slug>": [ {login, role}, ... ] },
#     repos:   { "<slug>": [ {name, permission}, ... ] } }
# SOURCE reads only.
_build_teams_snapshot() {
  local all_teams
  all_teams="$(gh_paginate ghsrc "orgs/$SOURCE_ORG/teams")"

  local members_map="{}" repos_map="{}"

  while IFS= read -r team; do
    local src_slug
    src_slug="$(echo "$team" | jq -r '.slug')"

    # Members with role
    local members member_list="[]"
    members="$(ghsrc api \
      "orgs/$SOURCE_ORG/teams/$src_slug/members?per_page=100&role=all" \
      --paginate 2>/dev/null | jq -rs '[.[] | select(type=="array") | .[] | select(type=="object")]')" || members='[]'
    while IFS= read -r member; do
      local login role
      login="$(echo "$member" | jq -r '.login')"
      [[ -z "$login" || "$login" == "null" ]] && continue
      role="$(ghsrc api "orgs/$SOURCE_ORG/teams/$src_slug/memberships/$login" \
        2>/dev/null | jq -rs '.[0].role // "member"' 2>/dev/null || echo 'member')"
      member_list="$(echo "$member_list" | jq --arg l "$login" --arg r "$role" '. + [{login:$l, role:$r}]')"
    done < <(echo "$members" | jq -c '.[]' 2>/dev/null || true)
    members_map="$(echo "$members_map" | jq --arg s "$src_slug" --argjson m "$member_list" '.[$s] = $m')"

    # Repo permissions
    local team_repos repo_list="[]"
    team_repos="$(ghsrc api \
      "orgs/$SOURCE_ORG/teams/$src_slug/repos?per_page=100" \
      --paginate 2>/dev/null | jq -rs '[.[] | select(type=="array") | .[] | select(type=="object")]')" || team_repos='[]'
    while IFS= read -r repo; do
      local repo_name permission
      repo_name="$(echo "$repo" | jq -r '.name')"
      permission="$(echo "$repo" | jq -r '.role_name // .permissions |
        if type == "string" then . elif .admin then "admin"
        elif .maintain then "maintain" elif .push then "push"
        elif .triage then "triage" else "pull" end' 2>/dev/null || echo 'pull')"
      repo_list="$(echo "$repo_list" | jq --arg n "$repo_name" --arg p "$permission" '. + [{name:$n, permission:$p}]')"
    done < <(echo "$team_repos" | jq -c '.[]' 2>/dev/null || true)
    repos_map="$(echo "$repos_map" | jq --arg s "$src_slug" --argjson r "$repo_list" '.[$s] = $r')"
  done < <(echo "$all_teams" | jq -c '.[]' 2>/dev/null || true)

  jq -n --argjson teams "$all_teams" --argjson members "$members_map" --argjson repos "$repos_map" \
    '{teams:$teams, members:$members, repos:$repos}'
}

# ---------------------------------------------------------------------------
main() {
  check_dry_run "$@"
  preflight

  log "Stage 10 — mirror-teams starting (mode=$MIRROR_MODE)"
  state_init "$STATE_FILE" "10-mirror-teams"

  # ---- Acquire snapshot ----------------------------------------------------
  local snapshot
  if in_import; then
    log "Loading teams snapshot from $STATE_FILE..."
    snapshot="$(jq -c '.source_snapshot // empty' "$STATE_FILE" 2>/dev/null || true)"
    if [[ -z "$snapshot" ]]; then
      err "No source_snapshot in $STATE_FILE — run MIRROR_MODE=export first"
      exit 1
    fi
  else
    log "Fetching teams (+members+repos) from $SOURCE_ORG..."
    snapshot="$(_build_teams_snapshot)"
  fi

  local all_teams members_map repos_map
  all_teams="$(echo "$snapshot" | jq -c '.teams // []')"
  members_map="$(echo "$snapshot" | jq -c '.members // {}')"
  repos_map="$(echo "$snapshot" | jq -c '.repos // {}')"

  local total_teams
  total_teams="$(echo "$all_teams" | jq 'length')"
  log "Found $total_teams teams"

  # ---- Export mode: persist snapshot and stop (no target writes) -----------
  if in_export; then
    local _tmp
    _tmp="$(mktemp)"
    jq --argjson snap "$snapshot" --arg ts "$(now)" \
      '.source_snapshot = $snap | .exported_at = $ts' "$STATE_FILE" > "$_tmp" && mv "$_tmp" "$STATE_FILE"
    ok "Stage 10 complete (export) — serialized $total_teams teams"
    [[ "$DRY_RUN" -eq 0 ]] && commit_state "mirror: export stage 10 (mirror-teams) [skip ci]"
    return 0
  fi

  [[ "$total_teams" -eq 0 ]] && { log "No teams to mirror."; return 0; }

  # ---- Load excluded teams + policy overrides from config ------------------
  local excluded_teams
  excluded_teams="$(jq -r '.stage_10_mirror_teams.exclude_teams[] // empty' \
    "$MIRROR_CONFIG" 2>/dev/null || true)"
  [[ -n "$excluded_teams" ]] && log "Excluded teams: $(echo "$excluded_teams" | tr '\n' ' ')"

  local force_privacy force_notification_setting
  force_privacy="$(jq -r '.stage_10_mirror_teams.force_privacy // empty' "$MIRROR_CONFIG" 2>/dev/null || true)"
  force_notification_setting="$(jq -r '.stage_10_mirror_teams.force_notification_setting // empty' "$MIRROR_CONFIG" 2>/dev/null || true)"
  [[ -n "$force_privacy" ]] && log "POLICY: all teams forced to privacy='$force_privacy'"
  [[ -n "$force_notification_setting" ]] && log "POLICY: all teams forced to notification_setting='$force_notification_setting'"

  # ---- Pre-fetch existing target teams ------------------------------------
  log "Fetching existing teams in $TARGET_ORG..."
  local tgt_teams_json
  tgt_teams_json="$(gh_paginate gh "orgs/$TARGET_ORG/teams" 2>/dev/null)" || tgt_teams_json='[]'

  # ---- Create teams — multi-pass topological sort -------------------------
  log "Creating teams (multi-pass for parent-child ordering)..."
  local remaining_teams="$all_teams"
  local pass=0 prev_remaining=999
  declare -A created_slug_to_target_id

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
      if [[ -n "$excluded_teams" ]] && echo "$excluded_teams" | grep -qx "$src_slug" 2>/dev/null; then
        log "  Skipping excluded team: $src_slug"
        continue
      fi
      local parent_slug parent_target_id=""
      parent_slug="$(echo "$team" | jq -r '.parent.slug // empty' 2>/dev/null || true)"
      if [[ -n "$parent_slug" ]]; then
        parent_target_id="${created_slug_to_target_id[$parent_slug]:-}"
        if [[ -z "$parent_target_id" ]]; then
          still_remaining="$(echo "$still_remaining" | jq --argjson t "$team" '. + [$t]')"
          continue
        fi
      fi
      _create_or_update_team "$team" "$parent_target_id" "$force_privacy" "$force_notification_setting"
      local result_id="${_LAST_TEAM_ID:-}"
      [[ -n "$result_id" ]] && created_slug_to_target_id["$src_slug"]="$result_id"
    done < <(echo "$remaining_teams" | jq -c '.[]' 2>/dev/null || true)
    remaining_teams="$still_remaining"
  done

  # ---- Sync members and repo permissions for every team -------------------
  if [[ "$INVITE_MEMBERS" -eq 0 ]]; then
    log "invite_members=false — syncing team repo permissions only (member sync skipped)"
  else
    log "Syncing team members and repo permissions..."
  fi

  while IFS= read -r team; do
    local src_slug
    src_slug="$(echo "$team" | jq -r '.slug')"
    if [[ -n "$excluded_teams" ]] && echo "$excluded_teams" | grep -qx "$src_slug" 2>/dev/null; then
      continue
    fi
    if [[ "$INVITE_MEMBERS" -eq 1 ]]; then
      _sync_team_members "$src_slug" "$(echo "$members_map" | jq -c --arg s "$src_slug" '.[$s] // []')"
    fi
    _sync_team_repos "$src_slug" "$(echo "$repos_map" | jq -c --arg s "$src_slug" '.[$s] // []')"
    pause 0.3
  done < <(echo "$all_teams" | jq -c '.[]' 2>/dev/null || true)

  # ---- Update stats and commit --------------------------------------------
  state_update_stats "$STATE_FILE"
  local total synced failed
  total="$(jq '.stats.total'   "$STATE_FILE")"
  synced="$(jq '.stats.synced' "$STATE_FILE")"
  failed="$(jq '.stats.failed' "$STATE_FILE")"
  log "Stage 10 complete — total=$total synced=$synced failed=$failed"

  if [[ "$DRY_RUN" -eq 0 ]]; then
    commit_state "mirror: state after stage 10 (mirror-teams, mode=$MIRROR_MODE) [skip ci]"
  fi
}

# ---------------------------------------------------------------------------
_LAST_TEAM_ID=""

_create_or_update_team() {
  local team="$1"
  local parent_target_id="${2:-}"
  local force_privacy="${3:-}"
  local force_notification_setting="${4:-}"
  _LAST_TEAM_ID=""

  local src_id src_slug src_name src_desc src_privacy
  src_id="$(echo      "$team" | jq -r '.id')"
  src_slug="$(echo    "$team" | jq -r '.slug')"
  src_name="$(echo    "$team" | jq -r '.name')"
  src_desc="$(echo    "$team" | jq -r '.description // ""')"
  src_privacy="$(echo "$team" | jq -r '.privacy // "secret"')"

  local effective_privacy="$src_privacy"
  if [[ -n "$force_privacy" && "$force_privacy" != "$src_privacy" ]]; then
    warn "  POLICY: team '$src_slug' privacy forced to '$force_privacy' (source: '$src_privacy')"
    effective_privacy="$force_privacy"
  elif [[ -n "$force_privacy" ]]; then
    effective_privacy="$force_privacy"
  fi

  local existing_tgt_id
  existing_tgt_id="$(gh api "orgs/$TARGET_ORG/teams/$src_slug" \
    2>/dev/null | jq -rs '.[0].id // empty' 2>/dev/null || true)"

  if [[ -n "$existing_tgt_id" ]]; then
    log "  Team '$src_slug' already exists (id=$existing_tgt_id)"
    _LAST_TEAM_ID="$existing_tgt_id"
    if [[ -n "$force_privacy" || -n "$force_notification_setting" ]]; then
      local patch_payload="{}"
      [[ -n "$force_privacy" ]] && \
        patch_payload="$(echo "$patch_payload" | jq --arg p "$force_privacy" '.privacy = $p')"
      [[ -n "$force_notification_setting" ]] && \
        patch_payload="$(echo "$patch_payload" | jq --arg ns "$force_notification_setting" '.notification_setting = $ns')"
      if ! dry_run_skip "patch team '$src_slug' in $TARGET_ORG (force privacy/notifications)"; then
        local _tmp
        _tmp="$(mktemp)"; printf '%s' "$patch_payload" > "$_tmp"
        gh api "orgs/$TARGET_ORG/teams/$src_slug" --method PATCH --input "$_tmp" \
          2>/dev/null || warn "  Failed to apply forced settings to existing team '$src_slug'"
        rm -f "$_tmp"
      fi
    fi
    _upsert_team "$src_id" "$src_slug" "$existing_tgt_id" "$src_name" "mirrored"
    return 0
  fi

  if dry_run_skip "create team $src_slug in $TARGET_ORG (parent_id=${parent_target_id:-none})"; then
    _upsert_team "$src_id" "$src_slug" "" "$src_name" "mirrored"
    return 0
  fi

  local payload
  payload="$(jq -n --arg name "$src_name" --arg desc "$src_desc" --arg privacy "$effective_privacy" \
    '{"name":$name,"description":$desc,"privacy":$privacy}')"
  if [[ -n "$parent_target_id" ]]; then
    payload="$(echo "$payload" | jq --argjson pid "$parent_target_id" '.parent_team_id = $pid')"
  fi
  if [[ -n "$force_notification_setting" ]]; then
    payload="$(echo "$payload" | jq --arg ns "$force_notification_setting" '.notification_setting = $ns')"
  fi

  local result _tmp
  _tmp="$(mktemp)"; printf '%s' "$payload" > "$_tmp"
  result="$(gh api "orgs/$TARGET_ORG/teams" --method POST --input "$_tmp" 2>/dev/null)" || result='FAILED'
  rm -f "$_tmp"

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
# _sync_team_members <slug> <members_json>
# members_json: [ {login, role}, ... ] (pre-fetched; no source access here).
_sync_team_members() {
  local src_slug="$1" members="$2"

  log "  Syncing members for team '$src_slug'..."

  local excluded_logins
  excluded_logins="$(jq -r '.stage_01_invite_people.exclude_logins[] // empty' \
    "$MIRROR_CONFIG" 2>/dev/null || true)"

  local member_count
  member_count="$(echo "$members" | jq 'length' 2>/dev/null || echo 0)"
  [[ "$member_count" -eq 0 ]] && { log "  No members in team '$src_slug'"; return 0; }

  local added=0 skipped=0 failed=0
  while IFS= read -r member; do
    local login role
    login="$(echo "$member" | jq -r '.login')"
    role="$(echo "$member" | jq -r '.role // "member"')"

    if [[ "$(echo "$login" | tr '[:upper:]' '[:lower:]')" == "dfc-acronis" ]]; then
      warn "CIRCUIT-BREAKER: team member sync for dfc-Acronis BLOCKED for team '$src_slug'"
      skipped=$((skipped + 1)); continue
    fi
    if [[ -n "$excluded_logins" ]] && echo "$excluded_logins" | grep -qi "^${login}$" 2>/dev/null; then
      log "  Skipping excluded login: $login for team '$src_slug'"
      skipped=$((skipped + 1)); continue
    fi

    if dry_run_skip "add $login (role=$role) to team $TARGET_ORG/$src_slug"; then
      added=$((added + 1)); continue
    fi

    local result
    result="$(gh api "orgs/$TARGET_ORG/teams/$src_slug/memberships/$login" \
      --method PUT -f role="$role" 2>/dev/null)" || result='FAILED'
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
# _sync_team_repos <slug> <repos_json>
# repos_json: [ {name, permission}, ... ] (pre-fetched; no source access here).
_sync_team_repos() {
  local src_slug="$1" team_repos="$2"

  log "  Syncing repo permissions for team '$src_slug'..."
  local repo_count
  repo_count="$(echo "$team_repos" | jq 'length' 2>/dev/null || echo 0)"
  [[ "$repo_count" -eq 0 ]] && return 0

  local synced=0 failed=0
  while IFS= read -r repo; do
    local repo_name permission
    repo_name="$(echo  "$repo" | jq -r '.name')"
    permission="$(echo "$repo" | jq -r '.permission // "pull"')"

    if dry_run_skip "set $permission on $TARGET_ORG/$repo_name for team $src_slug"; then
      synced=$((synced + 1)); continue
    fi
    local result
    result="$(gh api "orgs/$TARGET_ORG/teams/$src_slug/repos/$TARGET_ORG/$repo_name" \
      --method PUT -f permission="$permission" 2>/dev/null)" || result='FAILED'
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
  local src_id="$1" src_slug="$2" tgt_id="${3:-}" name="$4" status="$5"
  local ts
  ts="$(now)"
  local record
  record="$(jq -n \
    --argjson src_id "${src_id:-null}" --arg slug "$src_slug" \
    --argjson tgt_id "${tgt_id:-null}" --arg name "$name" \
    --arg status "$status" --arg ts "$ts" \
    '{source_id:$src_id, source_slug:$slug, target_id:$tgt_id, name:$name, status:$status, mirrored_at:$ts}')"
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
