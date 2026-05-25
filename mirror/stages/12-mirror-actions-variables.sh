#!/usr/bin/env bash
# mirror/stages/12-mirror-actions-variables.sh
# Mirror GitHub Actions VARIABLES (not secrets) from source to target.
#
# Variables are NOT secrets — their values are readable via the API and can
# be safely copied automatically.  This stage must run before CI/CD workflows
# in the target org are expected to work.
#
# Scope:
#   - Org-level Actions variables (GET /orgs/{org}/actions/variables)
#   - Repo-level Actions variables (GET /repos/{owner}/{repo}/actions/variables)
#
# NOT in scope (separate manual action required):
#   - Actions SECRETS — values are write-only; see stage 08 for name inventory
#   - Dependabot variables/secrets — not yet in REST API
#   - Environment-level variables — complex dependency on environments existing
#
# Org variable visibility:
#   If selected_repositories_count > 0 the source variable has a restricted
#   repo list.  The selected_repository_ids from source do NOT match target
#   repo IDs.  We apply visibility=all by default for those variables and log
#   a warning so operators can restrict access manually if needed.
#   Variables with visibility=all or visibility=private are copied as-is.
#
# Idempotency: checks if variable name already exists in target; updates if so.
#
# State file: state/actions-variables.yaml
#
# Usage:
#   SOURCE_ORG=cyberfabric TARGET_ORG=constructorfabric \
#   GH_TOKEN=xxx GH_TOKEN_SOURCE=xxx \
#   ./mirror/stages/12-mirror-actions-variables.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

TARGET_ORG="${TARGET_ORG:-constructorfabric}"
STATE_FILE="$REPO_ROOT/state/actions-variables.yaml"

# ---------------------------------------------------------------------------
main() {
  check_dry_run "$@"
  preflight

  log "Stage 12 — mirror-actions-variables starting"

  state_init "$STATE_FILE" "12-mirror-actions-variables"

  local excluded_repos
  excluded_repos="$(jq -r '.stage_12_mirror_actions_variables.exclude_repos[] // empty' \
    "$MIRROR_CONFIG" 2>/dev/null || true)"

  # ---- 1. Org-level Actions variables ------------------------------------
  log "Fetching org Actions variables from $SOURCE_ORG..."
  # BUG-01 fix: jq -s 'add // {} | .variables' does object-merge (last page wins).
  # Use map()+add to concatenate .variables arrays from all pages.
  local org_vars
  org_vars="$(ghsrc api "orgs/$SOURCE_ORG/actions/variables?per_page=100" \
    --paginate 2>/dev/null | jq -s 'map(.variables // []) | add // []' || echo '[]')"

  local org_var_count
  org_var_count="$(echo "$org_vars" | jq 'length' 2>/dev/null || echo 0)"
  log "Found $org_var_count org-level variables"

  # Pre-fetch existing target org vars for upsert
  local tgt_org_vars
  tgt_org_vars="$(gh api "orgs/$TARGET_ORG/actions/variables?per_page=100" \
    --paginate 2>/dev/null | jq -s 'map(.variables // []) | add // [] | [.[].name]' || echo '[]')"

  while IFS= read -r var; do
    local vname vvalue vvis
    vname="$(echo  "$var" | jq -r '.name')"
    vvalue="$(echo "$var" | jq -r '.value')"
    vvis="$(echo   "$var" | jq -r '.visibility // "all"')"

    # visibility=selected means per-repo list — IDs don't map to target; widen to all
    if [[ "$vvis" == "selected" ]]; then
      warn "  Org variable '$vname': visibility=selected — setting visibility=all in target (repo list cannot be mapped; restrict manually if needed)"
      vvis="all"
    fi

    _upsert_org_variable "$vname" "$vvalue" "$vvis" "$tgt_org_vars"
    pause 0.2
  done < <(echo "$org_vars" | jq -c '.[]' 2>/dev/null || true)

  # ---- 2. Repo-level Actions variables -----------------------------------
  log "Fetching source repos from $SOURCE_ORG..."
  local repos
  repos="$(gh_paginate ghsrc "orgs/$SOURCE_ORG/repos")"
  local total_repos
  total_repos="$(echo "$repos" | jq 'length')"
  log "Found $total_repos repos — syncing Actions variables..."

  local repo_idx=0

  while IFS= read -r repo; do
    local repo_name
    repo_name="$(echo "$repo" | jq -r '.name')"
    repo_idx=$((repo_idx + 1))

    if [[ -n "$excluded_repos" ]] && echo "$excluded_repos" | grep -qx "$repo_name" 2>/dev/null; then
      log "[$repo_idx/$total_repos] Skipping excluded repo: $repo_name"
      continue
    fi

    local repo_vars
    repo_vars="$(ghsrc api "repos/$SOURCE_ORG/$repo_name/actions/variables?per_page=100" \
      --paginate 2>/dev/null | jq -s 'map(.variables // []) | add // []' || echo '[]')"

    local rv_count
    rv_count="$(echo "$repo_vars" | jq 'length' 2>/dev/null || echo 0)"

    if [[ "$rv_count" -eq 0 ]]; then
      continue
    fi

    log "[$repo_idx/$total_repos] $repo_name: $rv_count variables"

    # Pre-fetch existing target repo vars
    local tgt_repo_vars
    tgt_repo_vars="$(gh api "repos/$TARGET_ORG/$repo_name/actions/variables?per_page=100" \
      --paginate 2>/dev/null | jq -s 'map(.variables // []) | add // [] | [.[].name]' || echo '[]')"

    while IFS= read -r var; do
      local vname vvalue
      vname="$(echo  "$var" | jq -r '.name')"
      vvalue="$(echo "$var" | jq -r '.value')"

      _upsert_repo_variable "$repo_name" "$vname" "$vvalue" "$tgt_repo_vars"
      pause 0.2
    done < <(echo "$repo_vars" | jq -c '.[]' 2>/dev/null || true)

    pause 0.3
  done < <(echo "$repos" | jq -c '.[]')

  state_update_stats "$STATE_FILE"

  local total synced failed
  total="$(jq '.stats.total'   "$STATE_FILE")"
  synced="$(jq '.stats.synced' "$STATE_FILE")"
  failed="$(jq '.stats.failed' "$STATE_FILE")"
  log "Stage 12 complete — total=$total synced=$synced failed=$failed"

  if [[ "$DRY_RUN" -eq 0 ]]; then
    commit_state "mirror: state after stage 12 (mirror-actions-variables) [skip ci]"
  fi
}

# ---------------------------------------------------------------------------
_upsert_org_variable() {
  local vname="$1"
  local vvalue="$2"
  local vvis="$3"
  local tgt_existing_names="$4"
  local ts
  ts="$(now)"

  local exists
  exists="$(echo "$tgt_existing_names" | jq -r --arg n "$vname" \
    '.[] | select(. == $n)' 2>/dev/null || true)"

  local status="synced"

  if dry_run_skip "upsert org variable '$vname' in $TARGET_ORG (visibility=$vvis)"; then
    status="synced"
  elif [[ -n "$exists" ]]; then
    local result
    result="$(gh api "orgs/$TARGET_ORG/actions/variables/$vname" \
      --method PATCH \
      -f name="$vname" -f value="$vvalue" -f visibility="$vvis" \
      2>/dev/null || echo 'FAILED')"
    [[ "$result" == "FAILED" ]] && { warn "  Failed to update org variable '$vname'"; status="failed"; } || \
      ok "  Updated org variable '$vname'"
  else
    local result
    result="$(gh api "orgs/$TARGET_ORG/actions/variables" \
      --method POST \
      -f name="$vname" -f value="$vvalue" -f visibility="$vvis" \
      2>/dev/null || echo 'FAILED')"
    [[ "$result" == "FAILED" ]] && { warn "  Failed to create org variable '$vname'"; status="failed"; } || \
      ok "  Created org variable '$vname'"
  fi

  local record
  record="$(jq -n \
    --arg scope  "org" \
    --arg name   "$vname" \
    --arg vis    "$vvis" \
    --arg status "$status" \
    --arg ts     "$ts" \
    '{"scope":$scope,"name":$name,"visibility":$vis,"status":$status,"synced_at":$ts}')"

  local tmp; tmp="$(mktemp)"
  jq --arg scope "org" --arg name "$vname" --argjson rec "$record" \
    'if (.items | map(select(.scope=="org" and .name==$name)) | length) > 0
     then .items = [.items[] | if (.scope=="org" and .name==$name) then $rec else . end]
     else .items += [$rec]
     end' "$STATE_FILE" > "$tmp"
  mv "$tmp" "$STATE_FILE"
}

# ---------------------------------------------------------------------------
_upsert_repo_variable() {
  local repo_name="$1"
  local vname="$2"
  local vvalue="$3"
  local tgt_existing_names="$4"
  local ts
  ts="$(now)"

  local exists
  exists="$(echo "$tgt_existing_names" | jq -r --arg n "$vname" \
    '.[] | select(. == $n)' 2>/dev/null || true)"

  local status="synced"

  if dry_run_skip "upsert repo variable '$vname' in $TARGET_ORG/$repo_name"; then
    status="synced"
  elif [[ -n "$exists" ]]; then
    local result
    result="$(gh api "repos/$TARGET_ORG/$repo_name/actions/variables/$vname" \
      --method PATCH \
      -f name="$vname" -f value="$vvalue" \
      2>/dev/null || echo 'FAILED')"
    [[ "$result" == "FAILED" ]] && { warn "  Failed to update variable '$vname' in $repo_name"; status="failed"; } || \
      ok "  Updated variable '$vname' in $repo_name"
  else
    local result
    result="$(gh api "repos/$TARGET_ORG/$repo_name/actions/variables" \
      --method POST \
      -f name="$vname" -f value="$vvalue" \
      2>/dev/null || echo 'FAILED')"
    [[ "$result" == "FAILED" ]] && { warn "  Failed to create variable '$vname' in $repo_name"; status="failed"; } || \
      ok "  Created variable '$vname' in $repo_name"
  fi

  local record
  record="$(jq -n \
    --arg scope  "repo" \
    --arg repo   "$repo_name" \
    --arg name   "$vname" \
    --arg status "$status" \
    --arg ts     "$ts" \
    '{"scope":$scope,"repo":$repo,"name":$name,"status":$status,"synced_at":$ts}')"

  local tmp; tmp="$(mktemp)"
  jq --arg scope "repo" --arg repo "$repo_name" --arg name "$vname" --argjson rec "$record" \
    'if (.items | map(select(.scope=="repo" and .repo==$repo and .name==$name)) | length) > 0
     then .items = [.items[] |
       if (.scope=="repo" and .repo==$repo and .name==$name) then $rec else . end]
     else .items += [$rec]
     end' "$STATE_FILE" > "$tmp"
  mv "$tmp" "$STATE_FILE"
}

main "$@"
