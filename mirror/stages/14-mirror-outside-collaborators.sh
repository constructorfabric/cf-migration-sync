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
# Modes (MIRROR_MODE):
#   full   — fetch source outside collaborators and add to target (default).
#   export — fetch them into a per-repo snapshot in state (.source_collaborators).
#            NEVER contacts the target org.
#   import — read the snapshot and add collaborators to target. NEVER source.
#
# Idempotency: PUT collaborators/{login} is an upsert; state tracks per (repo, login).
#
# State file: state/outside-collaborators/<repo-name>.yaml
#
# Usage:
#   SOURCE_ORG=cyberfabric TARGET_ORG=constructorfabric \
#   GH_TOKEN=xxx GH_TOKEN_SOURCE=xxx \
#   MIRROR_MODE=full|export|import \
#   ./mirror/stages/14-mirror-outside-collaborators.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

TARGET_ORG="${TARGET_ORG:-}"   # required; validated in preflight (no hardcoded default)
STATE_DIR="$REPO_ROOT/state/outside-collaborators"

# ---------------------------------------------------------------------------
main() {
  check_dry_run "$@"
  preflight

  log "Stage 14 — mirror-outside-collaborators starting (mode=$MIRROR_MODE)"

  # Backup-mode guard applies to anything that WRITES to target (full + import).
  # Export only reads the source, so it is allowed even in backup mode.
  if ! in_export && [[ "$INVITE_MEMBERS" -eq 0 ]]; then
    log "invite_members=false — stage 14 skipped (outside collaborator access requires active migration mode)"
    log "Set invite_members=true in mirror/config.json and re-run this stage to mirror collaborators"
    return 0
  fi

  mkdir -p "$STATE_DIR"

  local excluded_repos excluded_logins
  excluded_repos="$(jq -r '.stage_14_mirror_outside_collaborators.exclude_repos[] // empty' \
    "$MIRROR_CONFIG" 2>/dev/null || true)"
  excluded_logins="$(jq -r '.stage_01_invite_people.exclude_logins[] // empty' \
    "$MIRROR_CONFIG" 2>/dev/null || true)"

  if in_import; then
    _run_import "$excluded_repos" "$excluded_logins"
  else
    _run_source "$excluded_repos" "$excluded_logins"   # full + export
  fi

  log "Stage 14 complete"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    commit_state "mirror: state after stage 14 (mirror-outside-collaborators, mode=$MIRROR_MODE) [skip ci]"
  fi
}

# ---------------------------------------------------------------------------
_run_source() {
  local excluded_repos="$1" excluded_logins="$2"

  log "Fetching source repos from $SOURCE_ORG..."
  local repos total_repos
  repos="$(gh_paginate ghsrc "orgs/$SOURCE_ORG/repos")"
  total_repos="$(echo "$repos" | jq 'length')"
  log "Found $total_repos repos"

  local repo_idx=0
  while IFS= read -r repo; do
    local repo_name
    repo_name="$(echo "$repo" | jq -r '.name')"
    repo_idx=$((repo_idx + 1))
    if [[ -n "$excluded_repos" ]] && echo "$excluded_repos" | grep -qx "$repo_name" 2>/dev/null; then
      log "[$repo_idx/$total_repos] Skipping excluded repo: $repo_name"
      continue
    fi

    local collabs collab_count
    collabs="$(ghsrc api \
      "repos/$SOURCE_ORG/$repo_name/collaborators?affiliation=outside&per_page=100" \
      --paginate 2>/dev/null | jq -rs '[.[] | select(type=="array") | .[] | select(type=="object")]')" || collabs='[]'
    collab_count="$(echo "$collabs" | jq -r 'if type=="array" then length else 0 end' 2>/dev/null || echo 0)"
    [[ "$collab_count" -eq 0 ]] && continue

    log "[$repo_idx/$total_repos] $repo_name: $collab_count outside collaborators"
    local state_file="$STATE_DIR/$repo_name.yaml"
    state_init "$state_file" "14-mirror-outside-collaborators"

    if in_export; then
      local _c_tmp _tmp
      _c_tmp="$(mktemp)"; printf '%s' "$collabs" > "$_c_tmp"
      _tmp="$(mktemp)"
      jq --slurpfile c "$_c_tmp" --arg ts "$(now)" \
        '.source_collaborators = $c[0] | .exported_at = $ts' "$state_file" > "$_tmp" && mv "$_tmp" "$state_file"
      rm -f "$_c_tmp"
      ok "  [export] Serialized $collab_count collaborators for $repo_name"
    else
      _apply_collaborators "$repo_name" "$collabs" "$state_file" "$excluded_logins"
      state_update_stats "$state_file"
    fi
    pause 0.5
  done < <(echo "$repos" | jq -c '.[]')
}

# ---------------------------------------------------------------------------
_run_import() {
  local excluded_repos="$1" excluded_logins="$2"
  shopt -s nullglob
  local files=( "$STATE_DIR"/*.yaml )
  shopt -u nullglob
  if [[ ${#files[@]} -eq 0 ]]; then
    warn "No state files in $STATE_DIR — run MIRROR_MODE=export first"
    return 0
  fi
  local f
  for f in "${files[@]}"; do
    local repo_name collabs collab_count
    repo_name="$(basename "$f" .yaml)"
    if [[ -n "$excluded_repos" ]] && echo "$excluded_repos" | grep -qx "$repo_name" 2>/dev/null; then
      log "Skipping excluded repo: $repo_name"; continue
    fi
    collabs="$(jq -c '.source_collaborators // empty' "$f" 2>/dev/null || true)"
    [[ -z "$collabs" ]] && { warn "  No source_collaborators in $f — skipping $repo_name"; continue; }
    collab_count="$(echo "$collabs" | jq 'length' 2>/dev/null || echo 0)"
    [[ "$collab_count" -eq 0 ]] && continue
    log "Importing $collab_count outside collaborators for $repo_name..."
    _apply_collaborators "$repo_name" "$collabs" "$f" "$excluded_logins"
    state_update_stats "$f"
    pause 0.5
  done
}

# ---------------------------------------------------------------------------
# _apply_collaborators <repo> <collabs_json> <state_file> <excluded_logins>
# Adds each outside collaborator to the target repo. TARGET writes only.
_apply_collaborators() {
  local repo_name="$1" collabs="$2" state_file="$3" excluded_logins="$4"

  while IFS= read -r collab; do
    local login login_lower permission
    login="$(echo "$collab" | jq -r '.login')"
    login_lower="$(echo "$login" | tr '[:upper:]' '[:lower:]')"

    if [[ "$login_lower" == "dfc-acronis" ]]; then
      warn "CIRCUIT-BREAKER: collaborator dfc-Acronis BLOCKED for $repo_name"
      continue
    fi
    if [[ -n "$excluded_logins" ]] && echo "$excluded_logins" | grep -qi "^${login}$" 2>/dev/null; then
      log "  Skipping excluded collaborator: $login on $repo_name"
      _upsert_collaborator "$state_file" "$repo_name" "$login" "" "skipped"
      continue
    fi

    permission="$(echo "$collab" | jq -r '
      .role_name //
      (.permissions |
        if .admin    then "admin"
        elif .maintain then "maintain"
        elif .push   then "write"
        elif .triage then "triage"
        else "read"
        end)' 2>/dev/null || echo 'read')"

    local already_status already_perm
    already_status="$(jq -r --arg l "$login" \
      '.items[] | select(.login == $l) | .status // empty' \
      "$state_file" 2>/dev/null | head -1 || true)"
    already_perm="$(jq -r --arg l "$login" \
      '.items[] | select(.login == $l) | .permission // empty' \
      "$state_file" 2>/dev/null | head -1 || true)"
    # Skip if already synced — UNLESS CONTINUOUS mode and the source permission
    # changed since last run (then re-PUT the new permission; PUT is idempotent).
    if [[ "$already_status" == "synced" ]]; then
      if [[ "${CONTINUOUS:-false}" == "true" && "$already_perm" != "$permission" ]]; then
        log "  [continuous] $login permission changed ($already_perm → $permission) — re-applying"
      else
        continue
      fi
    fi

    if dry_run_skip "add collaborator $login ($permission) to $TARGET_ORG/$repo_name"; then
      _upsert_collaborator "$state_file" "$repo_name" "$login" "$permission" "synced"
      continue
    fi

    local result
    result="$(gh api "repos/$TARGET_ORG/$repo_name/collaborators/$login" \
      --method PUT -f permission="$permission" 2>/dev/null)" || result='FAILED'
    if [[ "$result" == "FAILED" ]]; then
      warn "  Failed to add $login ($permission) to $TARGET_ORG/$repo_name"
      _upsert_collaborator "$state_file" "$repo_name" "$login" "$permission" "failed"
    else
      ok "  Added $login ($permission) to $TARGET_ORG/$repo_name"
      _upsert_collaborator "$state_file" "$repo_name" "$login" "$permission" "synced"
    fi
    pause 0.3
  done < <(echo "$collabs" | jq -c '.[]' 2>/dev/null || true)
}

# ---------------------------------------------------------------------------
_upsert_collaborator() {
  local state_file="$1" repo_name="$2" login="$3" permission="$4" status="$5"
  local ts
  ts="$(now)"
  local record
  record="$(jq -n \
    --arg repo "$repo_name" --arg login "$login" --arg permission "$permission" \
    --arg status "$status" --arg ts "$ts" \
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
