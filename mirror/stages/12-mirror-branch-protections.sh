#!/usr/bin/env bash
# mirror/stages/12-mirror-branch-protections.sh
# Mirror per-repository branch protection rules to the target org.
#
# Two separate GitHub mechanisms are handled:
#
#   A. Repository Rulesets (modern — available on all plans)
#      GET  /repos/{org}/{repo}/rulesets
#      GET  /repos/{org}/{repo}/rulesets/{id}   (full detail)
#      POST /repos/{org}/{repo}/rulesets         (create)
#
#      Bypass actors with type="Team" are mapped by slug (teams must already
#      exist in target — run stage 10 first).  Actors of type="Integration"
#      (apps) are stripped with a warning because the app may not be installed.
#      Actors of type="RepositoryRole" and "OrganizationAdmin" are kept as-is
#      since these reference built-in roles that exist in every org.
#
#   B. Legacy branch protection rules (still widely used)
#      GET /repos/{org}/{repo}/branches?protected=true
#      GET /repos/{org}/{repo}/branches/{branch}/protection
#      PUT /repos/{org}/{repo}/branches/{branch}/protection
#
#      push restrictions.teams mapped by slug; restrictions.users kept by login;
#      restrictions.apps stripped (may not be installed in target).
#      If the target branch doesn't exist yet (git mirror incomplete), the rule
#      is recorded as status="failed" for re-run.
#
# Idempotency: state per repo tracks applied rules; existing-name rulesets are
# patched (PATCH) rather than re-created.
#
# Depends on: stage 02 (branches must exist), stage 10 (teams must exist for
#             bypass actor / push restriction mapping).
#
# State file: state/branch-protections/<repo-name>.yaml
#
# Usage:
#   SOURCE_ORG=cyberfabric TARGET_ORG=constructorfabric \
#   GH_TOKEN=xxx GH_TOKEN_SOURCE=xxx \
#   ./mirror/stages/12-mirror-branch-protections.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

TARGET_ORG="${TARGET_ORG:-constructorfabric}"
STATE_DIR="$REPO_ROOT/state/branch-protections"

# ---------------------------------------------------------------------------
main() {
  check_dry_run "$@"
  preflight

  log "Stage 12 — mirror-branch-protections starting"
  mkdir -p "$STATE_DIR"

  log "Fetching source repos from $SOURCE_ORG..."
  local repos
  repos="$(gh_paginate ghsrc "orgs/$SOURCE_ORG/repos")"
  local total_repos
  total_repos="$(echo "$repos" | jq 'length')"
  log "Found $total_repos repos"

  local excluded_repos
  excluded_repos="$(jq -r '.stage_12_mirror_branch_protections.exclude_repos[] // empty' \
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

    log "[$repo_idx/$total_repos] Processing branch protections for $repo_name..."
    _mirror_repo_protections "$repo_name"
    pause 0.5

  done < <(echo "$repos" | jq -c '.[]')

  log "Stage 12 complete"

  if [[ "$DRY_RUN" -eq 0 ]]; then
    commit_state "mirror: state after stage 12 (mirror-branch-protections) [skip ci]"
  fi
}

# ---------------------------------------------------------------------------
_mirror_repo_protections() {
  local repo_name="$1"
  local state_file="$STATE_DIR/$repo_name.yaml"

  state_init "$state_file" "12-mirror-branch-protections"

  # Pre-fetch target teams (slug → id) for bypass actor mapping.
  local tgt_teams
  tgt_teams="$(gh api "orgs/$TARGET_ORG/teams?per_page=100" \
    --paginate 2>/dev/null | jq -rs '[.[] | select(type == "object")]')" || tgt_teams='[]'

  # BUG-11 fix: pre-fetch source teams once here so _apply_ruleset can look up
  # bypass-actor team slugs without making a fresh paginated API call per actor.
  local src_teams
  src_teams="$(ghsrc api "orgs/$SOURCE_ORG/teams?per_page=100" \
    --paginate 2>/dev/null | jq -rs '[.[] | select(type == "object")]')" || src_teams='[]'

  # ---- A. Repository Rulesets -------------------------------------------
  log "  Fetching rulesets for $repo_name..."
  local rulesets
  rulesets="$(ghsrc api "repos/$SOURCE_ORG/$repo_name/rulesets?per_page=100" \
    2>/dev/null | jq -rs '.[0] // []' 2>/dev/null)" || rulesets='[]'

  local rs_count
  rs_count="$(echo "$rulesets" | jq 'length' 2>/dev/null || echo 0)"

  if [[ "$rs_count" -gt 0 ]]; then
    log "  Found $rs_count rulesets"

    # Pre-fetch existing target rulesets for idempotency
    local tgt_rulesets
    tgt_rulesets="$(gh api "repos/$TARGET_ORG/$repo_name/rulesets?per_page=100" \
      2>/dev/null | jq -rs '.[0] // []' 2>/dev/null)" || tgt_rulesets='[]'

    while IFS= read -r rs; do
      local rs_id rs_name
      rs_id="$(echo   "$rs" | jq -r '.id')"
      rs_name="$(echo "$rs" | jq -r '.name')"

      # Fetch full ruleset detail
      local rs_full
      rs_full="$(ghsrc api "repos/$SOURCE_ORG/$repo_name/rulesets/$rs_id" \
        2>/dev/null | jq -rs '.[0] // empty' 2>/dev/null || true)"

      if [[ -z "$rs_full" ]]; then
        warn "  Could not fetch ruleset details for '$rs_name' (id=$rs_id)"
        continue
      fi

      _apply_ruleset "$repo_name" "$rs_name" "$rs_full" "$tgt_rulesets" "$tgt_teams" "$state_file" "$src_teams"
      pause 0.3
    done < <(echo "$rulesets" | jq -c '.[]' 2>/dev/null || true)
  fi

  # ---- B. Legacy branch protection rules --------------------------------
  log "  Fetching protected branches for $repo_name..."
  local protected_branches
  protected_branches="$(ghsrc api \
    "repos/$SOURCE_ORG/$repo_name/branches?protected=true&per_page=100" \
    --paginate 2>/dev/null | jq -rs '[.[] | select(type == "object")]')" || protected_branches='[]'

  local pb_count
  pb_count="$(echo "$protected_branches" | jq -r 'if type=="array" then length else 0 end' 2>/dev/null || echo 0)"

  if [[ "$pb_count" -gt 0 ]]; then
    log "  Found $pb_count protected branches"

    while IFS= read -r branch_obj; do
      local branch_name
      branch_name="$(echo "$branch_obj" | jq -r '.name')"

      local protection
      protection="$(ghsrc api \
        "repos/$SOURCE_ORG/$repo_name/branches/$branch_name/protection" \
        2>/dev/null | jq -rs '.[0] // empty' 2>/dev/null || true)"

      if [[ -z "$protection" ]]; then
        log "  Branch '$branch_name' has no protection details (may be inherited ruleset)"
        continue
      fi

      _apply_legacy_protection "$repo_name" "$branch_name" "$protection" "$tgt_teams" "$state_file"
      pause 0.3
    done < <(echo "$protected_branches" | jq -c '.[]' 2>/dev/null || true)
  fi

  state_update_stats "$state_file"
}

# ---------------------------------------------------------------------------
# _apply_ruleset — create or patch a ruleset in the target repo.
# Strips bypass actors of type "Integration" (apps may not be installed).
# Maps Team bypass actors: source team id → target team id via slug lookup.
# ---------------------------------------------------------------------------
_apply_ruleset() {
  local repo_name="$1"
  local rs_name="$2"
  local rs_json="$3"
  local tgt_rulesets="$4"
  local tgt_teams="$5"
  local state_file="$6"
  # BUG-11 fix: accept pre-fetched source teams (avoids N per-actor API calls)
  local src_teams="${7:-}"
  local ts
  ts="$(now)"

  # Strip source-specific fields; keep structure
  local payload
  payload="$(echo "$rs_json" | jq \
    'del(.id, .source, .source_type, .created_at, .updated_at, .node_id,
         ._links, .current_user_can_bypass)')"

  # Fix bypass_actors: keep RepositoryRole + OrganizationAdmin, strip Integration,
  # remap Team ids from source to target via slug
  local bypass_actors
  bypass_actors="$(echo "$rs_json" | jq -c \
    '.bypass_actors // [] | map(select(.actor_type != "Integration"))')"

  # Remap team IDs (actor_type == "Team"): source actor_id → target team id via slug
  local remapped_actors="[]"
  while IFS= read -r actor; do
    local atype actor_id
    atype="$(echo    "$actor" | jq -r '.actor_type')"
    actor_id="$(echo "$actor" | jq -r '.actor_id')"

    if [[ "$atype" == "Team" ]]; then
      # Look up source team slug using the pre-fetched src_teams (no extra API call).
      local src_team_slug
      if [[ -n "$src_teams" && "$src_teams" != "[]" ]]; then
        src_team_slug="$(echo "$src_teams" | jq -r --argjson id "$actor_id" \
          '.[] | select(.id == $id) | .slug' 2>/dev/null | head -1 || true)"
      else
        # Fallback: fetch on demand if src_teams was not pre-populated
        src_team_slug="$(ghsrc api "orgs/$SOURCE_ORG/teams?per_page=100" \
          --paginate 2>/dev/null | jq -s --argjson id "$actor_id" \
          'add // [] | .[] | select(.id == $id) | .slug' 2>/dev/null | head -1 | tr -d '"' || true)"
      fi

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

  # Check if a same-named ruleset already exists in target
  local existing_id
  existing_id="$(echo "$tgt_rulesets" | jq -r \
    --arg name "$rs_name" '.[] | select(.name == $name) | .id' \
    2>/dev/null | head -1 || true)"

  local status="synced"
  if dry_run_skip "apply ruleset '$rs_name' to $TARGET_ORG/$repo_name"; then
    status="synced"
  elif [[ -n "$existing_id" ]]; then
    local patch_result
    patch_result="$(gh api "repos/$TARGET_ORG/$repo_name/rulesets/$existing_id" \
      --method PUT --input <(echo "$payload") \
      2>/dev/null)" || patch_result='FAILED'
    if [[ "$patch_result" == "FAILED" ]]; then
      warn "  Failed to update ruleset '$rs_name' in $TARGET_ORG/$repo_name"
      status="failed"
    else
      ok "  Updated ruleset '$rs_name' in $TARGET_ORG/$repo_name"
    fi
  else
    local create_result
    create_result="$(gh api "repos/$TARGET_ORG/$repo_name/rulesets" \
      --method POST --input <(echo "$payload") \
      2>/dev/null)" || create_result='FAILED'
    if [[ "$create_result" == "FAILED" ]]; then
      warn "  Failed to create ruleset '$rs_name' in $TARGET_ORG/$repo_name"
      status="failed"
    else
      ok "  Created ruleset '$rs_name' in $TARGET_ORG/$repo_name"
    fi
  fi

  # Upsert state
  local record
  record="$(jq -n \
    --arg type   "ruleset" \
    --arg name   "$rs_name" \
    --arg status "$status" \
    --arg ts     "$ts" \
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
# Strips apps from restrictions (may not be installed in target).
# Maps team slugs in restrictions (trusted to match since stage 10 ran).
# ---------------------------------------------------------------------------
_apply_legacy_protection() {
  local repo_name="$1"
  local branch_name="$2"
  local prot_json="$3"
  local tgt_teams="$4"  # unused here — team slugs used directly
  local state_file="$5"
  local ts
  ts="$(now)"

  # Build PUT payload from GET response
  # GET returns nested objects with "enabled" fields; PUT takes flat booleans.
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

  # Note if apps were stripped from restrictions
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
    local result
    result="$(gh api "repos/$TARGET_ORG/$repo_name/branches/$branch_name/protection" \
      --method PUT --input <(echo "$payload") \
      2>/dev/null)" || result='FAILED'

    if [[ "$result" == "FAILED" ]]; then
      warn "  Failed to set protection for $TARGET_ORG/$repo_name/$branch_name (branch may not exist yet)"
      status="failed"
    else
      ok "  Set branch protection for $TARGET_ORG/$repo_name/$branch_name"
    fi
  fi

  local record
  record="$(jq -n \
    --arg type   "legacy_protection" \
    --arg branch "$branch_name" \
    --arg status "$status" \
    --arg ts     "$ts" \
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
