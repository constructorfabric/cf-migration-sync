#!/usr/bin/env bash
# mirror/stages/12-mirror-branch-protections.sh
# Mirror per-repository branch protection rules to the target org.
#
# Two separate GitHub mechanisms are handled:
#
#   A. Repository Rulesets (modern — available on all plans)
#      Bypass actors with type="Team" are mapped by slug (teams must already
#      exist in target — run stage 10 first).  Actors of type="Integration"
#      (apps) are stripped with a warning.  RepositoryRole and OrganizationAdmin
#      actors are kept as-is.
#
#   B. Legacy branch protection rules
#      push restrictions.teams mapped by slug; restrictions.users kept by login;
#      restrictions.apps stripped.  Missing target branch → status="failed".
#
# Modes (MIRROR_MODE):
#   full   — fetch source rulesets + legacy protections and apply to target (default).
#   export — fetch them into a per-repo snapshot in state (.source_snapshot,
#            including the source teams list for bypass-actor mapping). NEVER
#            contacts the target org.
#   import — read the snapshot and apply to target (reads target teams/rulesets for
#            mapping + idempotency, allowed). NEVER contacts the source org.
#
# Depends on: stage 02 (branches), stage 10 (teams for actor/restriction mapping).
#
# State file: state/branch-protections/<repo-name>.yaml
#
# Usage:
#   SOURCE_ORG=cyberfabric TARGET_ORG=constructorfabric \
#   GH_TOKEN=xxx GH_TOKEN_SOURCE=xxx \
#   MIRROR_MODE=full|export|import \
#   ./mirror/stages/12-mirror-branch-protections.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

TARGET_ORG="${TARGET_ORG:-}"   # required; validated in preflight (no hardcoded default)
STATE_DIR="$REPO_ROOT/state/branch-protections"

# ---------------------------------------------------------------------------
main() {
  check_dry_run "$@"
  preflight

  log "Stage 12 — mirror-branch-protections starting (mode=$MIRROR_MODE)"
  mkdir -p "$STATE_DIR"

  local excluded_repos
  excluded_repos="$(jq -r '.stage_12_mirror_branch_protections.exclude_repos[] // empty' \
    "$MIRROR_CONFIG" 2>/dev/null || true)"

  if in_import; then
    _run_import "$excluded_repos"
  else
    _run_source "$excluded_repos"   # full + export
  fi

  log "Stage 12 complete"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    commit_state "mirror: state after stage 12 (mirror-branch-protections, mode=$MIRROR_MODE) [skip ci]"
  fi
}

# ---------------------------------------------------------------------------
_run_source() {
  local excluded_repos="$1"
  log "Fetching source repos from $SOURCE_ORG..."
  local repos total_repos
  repos="$(gh_paginate ghsrc "orgs/$SOURCE_ORG/repos")"
  total_repos="$(echo "$repos" | jq 'length')"
  log "Found $total_repos repos"

  # Source teams (org-global) — fetched once, used for bypass-actor mapping.
  local src_teams
  src_teams="$(ghsrc api "orgs/$SOURCE_ORG/teams?per_page=100" --paginate 2>/dev/null \
    | jq -rs '[.[] | select(type=="array") | .[] | select(type=="object")]')" || src_teams='[]'

  local repo_idx=0
  while IFS= read -r repo; do
    local repo_name
    repo_name="$(echo "$repo" | jq -r '.name')"
    repo_idx=$((repo_idx + 1))
    if [[ -n "$excluded_repos" ]] && echo "$excluded_repos" | grep -qx "$repo_name" 2>/dev/null; then
      log "[$repo_idx/$total_repos] Skipping excluded repo: $repo_name"
      continue
    fi

    log "[$repo_idx/$total_repos] Processing branch protections for $repo_name..."
    local state_file="$STATE_DIR/$repo_name.yaml"
    state_init "$state_file" "12-mirror-branch-protections"

    local snapshot
    snapshot="$(_build_protections_snapshot "$repo_name" "$src_teams")"

    if in_export; then
      local _snap_tmp _tmp
      _snap_tmp="$(mktemp)"; printf '%s' "$snapshot" > "$_snap_tmp"
      _tmp="$(mktemp)"
      jq --slurpfile snap "$_snap_tmp" --arg ts "$(now)" \
        '.source_snapshot = $snap[0] | .exported_at = $ts' "$state_file" > "$_tmp" && mv "$_tmp" "$state_file"
      rm -f "$_snap_tmp"
      ok "  [export] Snapshot stored for $repo_name"
    else
      _apply_protections_snapshot "$repo_name" "$snapshot" "$state_file"
    fi
    pause 0.5
  done < <(echo "$repos" | jq -c '.[]')
}

# ---------------------------------------------------------------------------
_run_import() {
  local excluded_repos="$1"
  shopt -s nullglob
  local files=( "$STATE_DIR"/*.yaml )
  shopt -u nullglob
  if [[ ${#files[@]} -eq 0 ]]; then
    warn "No state files in $STATE_DIR — run MIRROR_MODE=export first"
    return 0
  fi
  local f
  for f in "${files[@]}"; do
    local repo_name snapshot
    repo_name="$(basename "$f" .yaml)"
    if [[ -n "$excluded_repos" ]] && echo "$excluded_repos" | grep -qx "$repo_name" 2>/dev/null; then
      log "Skipping excluded repo: $repo_name"; continue
    fi
    snapshot="$(jq -c '.source_snapshot // empty' "$f" 2>/dev/null || true)"
    [[ -z "$snapshot" ]] && { warn "  No source_snapshot in $f — skipping $repo_name"; continue; }
    log "Importing branch protections for $repo_name..."
    _apply_protections_snapshot "$repo_name" "$snapshot" "$f"
    pause 0.5
  done
}

# ---------------------------------------------------------------------------
# _build_protections_snapshot <repo> <src_teams_json> — fetch rulesets (full
# detail) + legacy protections for one repo. SOURCE reads only.
_build_protections_snapshot() {
  local repo_name="$1" src_teams="$2"

  # Rulesets — list, then full detail per ruleset.
  local rulesets rs_fulls="[]"
  rulesets="$(ghsrc api "repos/$SOURCE_ORG/$repo_name/rulesets?per_page=100" \
    2>/dev/null | jq -rs '.[0] // []' 2>/dev/null)" || rulesets='[]'
  while IFS= read -r rs; do
    local rs_id rs_name rs_full
    rs_id="$(echo "$rs" | jq -r '.id')"
    rs_name="$(echo "$rs" | jq -r '.name')"
    rs_full="$(ghsrc api "repos/$SOURCE_ORG/$repo_name/rulesets/$rs_id" \
      2>/dev/null | jq -rs '.[0] // empty' 2>/dev/null || true)"
    [[ -z "$rs_full" ]] && { warn "  Could not fetch ruleset details for '$rs_name' (id=$rs_id)"; continue; }
    rs_fulls="$(echo "$rs_fulls" | jq --argjson r "$rs_full" '. + [$r]')"
  done < <(echo "$rulesets" | jq -c '.[]' 2>/dev/null || true)

  # Legacy protections — protected branches, then protection detail per branch.
  local protected_branches legacy="[]"
  protected_branches="$(ghsrc api \
    "repos/$SOURCE_ORG/$repo_name/branches?protected=true&per_page=100" \
    --paginate 2>/dev/null | jq -rs '[.[] | select(type=="array") | .[] | select(type=="object")]')" || protected_branches='[]'
  while IFS= read -r branch_obj; do
    local branch_name protection
    branch_name="$(echo "$branch_obj" | jq -r '.name')"
    protection="$(ghsrc api \
      "repos/$SOURCE_ORG/$repo_name/branches/$branch_name/protection" \
      2>/dev/null | jq -rs '.[0] // empty' 2>/dev/null || true)"
    [[ -z "$protection" ]] && { log "  Branch '$branch_name' has no protection details (may be inherited ruleset)"; continue; }
    legacy="$(echo "$legacy" | jq --arg b "$branch_name" --argjson p "$protection" '. + [{branch:$b, protection:$p}]')"
  done < <(echo "$protected_branches" | jq -c '.[]' 2>/dev/null || true)

  jq -n --argjson rulesets "$rs_fulls" --argjson legacy "$legacy" --argjson src_teams "$src_teams" \
    '{rulesets:$rulesets, legacy:$legacy, src_teams:$src_teams}'
}

# ---------------------------------------------------------------------------
# _apply_protections_snapshot — apply a snapshot to the target. Reads target
# teams + rulesets (allowed in import). Shared by full + import.
_apply_protections_snapshot() {
  local repo_name="$1" snapshot="$2" state_file="$3"

  local src_teams rulesets legacy
  src_teams="$(echo "$snapshot" | jq -c '.src_teams // []')"
  rulesets="$(echo "$snapshot" | jq -c '.rulesets // []')"
  legacy="$(echo "$snapshot" | jq -c '.legacy // []')"

  local tgt_teams
  tgt_teams="$(gh api "orgs/$TARGET_ORG/teams?per_page=100" --paginate 2>/dev/null \
    | jq -rs '[.[] | select(type=="array") | .[] | select(type=="object")]')" || tgt_teams='[]'

  # ---- A. Rulesets --------------------------------------------------------
  local rs_count
  rs_count="$(echo "$rulesets" | jq 'length' 2>/dev/null || echo 0)"
  if [[ "$rs_count" -gt 0 ]]; then
    log "  Applying $rs_count rulesets for $repo_name..."
    local tgt_rulesets
    tgt_rulesets="$(gh api "repos/$TARGET_ORG/$repo_name/rulesets?per_page=100" \
      2>/dev/null | jq -rs '.[0] // []' 2>/dev/null)" || tgt_rulesets='[]'
    while IFS= read -r rs_full; do
      local rs_name
      rs_name="$(echo "$rs_full" | jq -r '.name')"
      _apply_ruleset "$repo_name" "$rs_name" "$rs_full" "$tgt_rulesets" "$tgt_teams" "$state_file" "$src_teams"
      pause 0.3
    done < <(echo "$rulesets" | jq -c '.[]' 2>/dev/null || true)
  fi

  # ---- B. Legacy protections ---------------------------------------------
  local lg_count
  lg_count="$(echo "$legacy" | jq 'length' 2>/dev/null || echo 0)"
  if [[ "$lg_count" -gt 0 ]]; then
    log "  Applying $lg_count legacy protections for $repo_name..."
    while IFS= read -r entry; do
      local branch_name protection
      branch_name="$(echo "$entry" | jq -r '.branch')"
      protection="$(echo "$entry" | jq -c '.protection')"
      _apply_legacy_protection "$repo_name" "$branch_name" "$protection" "$tgt_teams" "$state_file"
      pause 0.3
    done < <(echo "$legacy" | jq -c '.[]' 2>/dev/null || true)
  fi

  state_update_stats "$state_file"
}

# ---------------------------------------------------------------------------
# _apply_ruleset — create or patch a ruleset in the target repo.
_apply_ruleset() {
  local repo_name="$1" rs_name="$2" rs_json="$3" tgt_rulesets="$4" tgt_teams="$5" state_file="$6" src_teams="${7:-[]}"
  local ts
  ts="$(now)"

  local payload
  payload="$(echo "$rs_json" | jq \
    'del(.id, .source, .source_type, .created_at, .updated_at, .node_id,
         ._links, .current_user_can_bypass)')"

  local bypass_actors
  bypass_actors="$(echo "$rs_json" | jq -c \
    '.bypass_actors // [] | map(select(.actor_type != "Integration"))')"

  local remapped_actors="[]"
  while IFS= read -r actor; do
    local atype actor_id
    atype="$(echo    "$actor" | jq -r '.actor_type')"
    actor_id="$(echo "$actor" | jq -r '.actor_id')"

    if [[ "$atype" == "Team" ]]; then
      local src_team_slug
      src_team_slug="$(echo "$src_teams" | jq -r --argjson id "$actor_id" \
        '.[] | select(.id == $id) | .slug' 2>/dev/null | head -1 || true)"
      if [[ -n "$src_team_slug" ]]; then
        local tgt_team_id
        tgt_team_id="$(echo "$tgt_teams" | jq -r \
          --arg slug "$src_team_slug" '.[] | select(.slug == $slug) | .id' \
          2>/dev/null | head -1 || true)"
        if [[ -n "$tgt_team_id" ]]; then
          actor="$(echo "$actor" | jq --argjson id "$tgt_team_id" '.actor_id = $id')"
        else
          warn "  Ruleset '$rs_name': team slug '$src_team_slug' not found in target — bypass actor dropped"
          continue
        fi
      else
        warn "  Ruleset '$rs_name': could not resolve source team id=$actor_id — bypass actor dropped"
        continue
      fi
    fi
    remapped_actors="$(echo "$remapped_actors" | jq --argjson a "$actor" '. + [$a]')"
  done < <(echo "$bypass_actors" | jq -c '.[]' 2>/dev/null || true)

  payload="$(echo "$payload" | jq --argjson ba "$remapped_actors" '.bypass_actors = $ba')"

  local existing_id
  existing_id="$(echo "$tgt_rulesets" | jq -r \
    --arg name "$rs_name" '.[] | select(.name == $name) | .id' \
    2>/dev/null | head -1 || true)"

  local status="synced"
  if dry_run_skip "apply ruleset '$rs_name' to $TARGET_ORG/$repo_name"; then
    status="synced"
  else
    local _tmp
    _tmp="$(mktemp)"; printf '%s' "$payload" > "$_tmp"
    if [[ -n "$existing_id" ]]; then
      local patch_result
      patch_result="$(gh api "repos/$TARGET_ORG/$repo_name/rulesets/$existing_id" \
        --method PUT --input "$_tmp" 2>/dev/null)" || patch_result='FAILED'
      if [[ "$patch_result" == "FAILED" ]]; then
        warn "  Failed to update ruleset '$rs_name' in $TARGET_ORG/$repo_name"; status="failed"
      else
        ok "  Updated ruleset '$rs_name' in $TARGET_ORG/$repo_name"
      fi
    else
      local create_result
      create_result="$(gh api "repos/$TARGET_ORG/$repo_name/rulesets" \
        --method POST --input "$_tmp" 2>/dev/null)" || create_result='FAILED'
      if [[ "$create_result" == "FAILED" ]]; then
        warn "  Failed to create ruleset '$rs_name' in $TARGET_ORG/$repo_name"; status="failed"
      else
        ok "  Created ruleset '$rs_name' in $TARGET_ORG/$repo_name"
      fi
    fi
    rm -f "$_tmp"
  fi

  local record
  record="$(jq -n --arg type "ruleset" --arg name "$rs_name" --arg status "$status" --arg ts "$ts" \
    '{"type":$type,"name":$name,"status":$status,"synced_at":$ts}')"
  local tmp; tmp="$(mktemp)"
  jq --arg name "$rs_name" --argjson rec "$record" \
    'if (.items | map(select(.type=="ruleset" and .name==$name)) | length) > 0
     then .items = [.items[] | if (.type=="ruleset" and .name==$name) then $rec else . end]
     else .items += [$rec]
     end' "$state_file" > "$tmp"
  mv "$tmp" "$state_file"
}

# ---------------------------------------------------------------------------
# _apply_legacy_protection — translate GET format → PUT format and apply.
_apply_legacy_protection() {
  local repo_name="$1" branch_name="$2" prot_json="$3" tgt_teams="$4" state_file="$5"
  local ts
  ts="$(now)"

  local payload
  payload="$(echo "$prot_json" | jq '
    {
      "required_status_checks": (
        if .required_status_checks then {
          "strict":   (.required_status_checks.strict // false),
          "contexts": (.required_status_checks.contexts // [])
        } else null end
      ),
      "enforce_admins": (
        if (.enforce_admins | type) == "object"
        then .enforce_admins.enabled
        else (.enforce_admins // false)
        end
      ),
      "required_pull_request_reviews": (
        if .required_pull_request_reviews then {
          "dismissal_restrictions": {
            "users": ([(.required_pull_request_reviews.dismissal_restrictions.users // [])[] | .login]),
            "teams": ([(.required_pull_request_reviews.dismissal_restrictions.teams // [])[] | .slug])
          },
          "dismiss_stale_reviews":            (.required_pull_request_reviews.dismiss_stale_reviews // false),
          "require_code_owner_reviews":       (.required_pull_request_reviews.require_code_owner_reviews // false),
          "required_approving_review_count":  (.required_pull_request_reviews.required_approving_review_count // 1),
          "require_last_push_approval":       (.required_pull_request_reviews.require_last_push_approval // false)
        } else null end
      ),
      "restrictions": (
        if .restrictions and (.restrictions | type) == "object" then {
          "users": ([(.restrictions.users // [])[] | .login]),
          "teams": ([(.restrictions.teams // [])[] | .slug]),
          "apps":  []
        } else null end
      ),
      "required_linear_history":          ((.required_linear_history.enabled)           // false),
      "allow_force_pushes":               ((.allow_force_pushes.enabled)                // false),
      "allow_deletions":                  ((.allow_deletions.enabled)                   // false),
      "required_conversation_resolution": ((.required_conversation_resolution.enabled)  // false),
      "lock_branch":                      ((.lock_branch.enabled)                       // false),
      "allow_fork_syncing":               ((.allow_fork_syncing.enabled)                // false)
    }
  ')"

  local had_app_restrictions
  had_app_restrictions="$(echo "$prot_json" | jq \
    '(.restrictions.apps // [] | length) > 0' 2>/dev/null || echo 'false')"
  if [[ "$had_app_restrictions" == "true" ]]; then
    warn "  Branch '$branch_name': app push restrictions not copied (apps must be re-installed in target)"
  fi

  local status="synced"
  if dry_run_skip "PUT branch protection for $TARGET_ORG/$repo_name/$branch_name"; then
    status="synced"
  else
    local _tmp result
    _tmp="$(mktemp)"; printf '%s' "$payload" > "$_tmp"
    result="$(gh api "repos/$TARGET_ORG/$repo_name/branches/$branch_name/protection" \
      --method PUT --input "$_tmp" 2>/dev/null)" || result='FAILED'
    rm -f "$_tmp"
    if [[ "$result" == "FAILED" ]]; then
      warn "  Failed to set protection for $TARGET_ORG/$repo_name/$branch_name (branch may not exist yet)"
      status="failed"
    else
      ok "  Set branch protection for $TARGET_ORG/$repo_name/$branch_name"
    fi
  fi

  local record
  record="$(jq -n --arg type "legacy_protection" --arg branch "$branch_name" --arg status "$status" --arg ts "$ts" \
    '{"type":$type,"branch":$branch,"status":$status,"synced_at":$ts}')"
  local tmp; tmp="$(mktemp)"
  jq --arg branch "$branch_name" --argjson rec "$record" \
    'if (.items | map(select(.type=="legacy_protection" and .branch==$branch)) | length) > 0
     then .items = [.items[] | if (.type=="legacy_protection" and .branch==$branch) then $rec else . end]
     else .items += [$rec]
     end' "$state_file" > "$tmp"
  mv "$tmp" "$state_file"
}

main "$@"
