#!/usr/bin/env bash
# mirror/stages/13-mirror-actions-variables.sh
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
#   - Actions SECRETS — values are write-only; see stage 09 for name inventory
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
# Modes (MIRROR_MODE):
#   full   — fetch source variables (org + repo) and apply to target (default).
#   export — fetch source variables into state (.source_snapshot). NEVER target.
#   import — read serialized variables from state and apply to target. NEVER source.
#
# Usage:
#   SOURCE_ORG=cyberfabric TARGET_ORG=constructorfabric \
#   GH_TOKEN=xxx GH_TOKEN_SOURCE=xxx \
#   MIRROR_MODE=full|export|import \
#   ./mirror/stages/13-mirror-actions-variables.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

TARGET_ORG="${TARGET_ORG:-}"   # required; validated in preflight (no hardcoded default)
STATE_FILE="$REPO_ROOT/state/actions-variables.yaml"

# ---------------------------------------------------------------------------
main() {
  check_dry_run "$@"
  preflight

  log "Stage 13 — mirror-actions-variables starting (mode=$MIRROR_MODE)"

  state_init "$STATE_FILE" "13-mirror-actions-variables"

  local excluded_repos
  excluded_repos="$(jq -r '.stage_13_mirror_actions_variables.exclude_repos[] // empty' \
    "$MIRROR_CONFIG" 2>/dev/null || true)"

  # ---- Acquire snapshot: { org_vars:[...], repo_vars:{ "<repo>":[...] } } --
  # full/export → fetch from source. import → load from state.
  local org_vars repo_vars_map
  if in_import; then
    log "Loading variables snapshot from $STATE_FILE..."
    local snap
    snap="$(jq -c '.source_snapshot // empty' "$STATE_FILE" 2>/dev/null || true)"
    if [[ -z "$snap" ]]; then
      err "No source_snapshot in $STATE_FILE — run MIRROR_MODE=export first"; exit 1
    fi
    org_vars="$(echo "$snap" | jq -c '.org_vars // []')"
    repo_vars_map="$(echo "$snap" | jq -c '.repo_vars // {}')"
  else
    log "Fetching org Actions variables from $SOURCE_ORG..."
    # C2 FIX: gh_flatten_wrapper warns instead of silently dropping error pages.
    org_vars="$(gh_flatten_wrapper ghsrc "orgs/$SOURCE_ORG/actions/variables" variables)"

    log "Fetching source repos from $SOURCE_ORG..."
    local repos
    repos="$(gh_paginate ghsrc "orgs/$SOURCE_ORG/repos")"
    repo_vars_map="{}"
    while IFS= read -r repo; do
      local repo_name repo_vars rv_count
      repo_name="$(echo "$repo" | jq -r '.name')"
      if [[ -n "$excluded_repos" ]] && echo "$excluded_repos" | grep -qx "$repo_name" 2>/dev/null; then
        continue
      fi
      repo_vars="$(gh_flatten_wrapper ghsrc "repos/$SOURCE_ORG/$repo_name/actions/variables" variables)"
      rv_count="$(echo "$repo_vars" | jq 'length' 2>/dev/null || echo 0)"
      [[ "$rv_count" -eq 0 ]] && continue
      repo_vars_map="$(echo "$repo_vars_map" | jq --arg r "$repo_name" --argjson v "$repo_vars" '.[$r] = $v')"
    done < <(echo "$repos" | jq -c '.[]')
  fi

  # ---- Export mode: persist snapshot and stop (no target writes) ----------
  if in_export; then
    local oc rc_total
    oc="$(echo "$org_vars" | jq 'length')"
    rc_total="$(echo "$repo_vars_map" | jq '[.[] | length] | add // 0')"
    local _ov_tmp _rv_tmp _tmp
    _ov_tmp="$(mktemp)"; printf '%s' "$org_vars" > "$_ov_tmp"
    _rv_tmp="$(mktemp)"; printf '%s' "$repo_vars_map" > "$_rv_tmp"
    _tmp="$(mktemp)"
    jq --slurpfile ov "$_ov_tmp" --slurpfile rv "$_rv_tmp" --arg ts "$(now)" \
      '.source_snapshot = {org_vars:$ov[0], repo_vars:$rv[0]} | .exported_at = $ts' \
      "$STATE_FILE" > "$_tmp" && mv "$_tmp" "$STATE_FILE"
    rm -f "$_ov_tmp" "$_rv_tmp"
    ok "Stage 13 complete (export) — serialized org=$oc repo=$rc_total variables"
    [[ "$DRY_RUN" -eq 0 ]] && commit_state "mirror: export stage 13 (actions-variables) [skip ci]"
    return 0
  fi

  # ---- Apply (full + import) ----------------------------------------------
  local org_var_count
  org_var_count="$(echo "$org_vars" | jq 'length' 2>/dev/null || echo 0)"
  log "Applying $org_var_count org-level variables..."

  # H6 FIX (RC-5 corollary): fetch the existing target vars OUT-OF-BAND. Piping
  # gh→jq hides gh's exit code and lets a 404/scope-error body parse to [] — which
  # would make the dedup think "no vars exist" and create DUPLICATES of every var.
  # If the fetch fails, skip org-var application this run rather than risk dups.
  local _tgt_raw tgt_org_vars
  if _tgt_raw="$(gh api "orgs/$TARGET_ORG/actions/variables?per_page=100" --paginate 2>/dev/null)"; then
    tgt_org_vars="$(printf '%s' "$_tgt_raw" | jq -rs '[.[] | select(type == "object") | select(has("variables")) | .variables[] | select(type == "object") | .name]' 2>/dev/null || echo '[]')"
  else
    warn "  Could not list existing org variables in $TARGET_ORG (404/scope?) — skipping org-variable apply to avoid creating duplicates"
    tgt_org_vars=""
  fi

  if [[ -n "$tgt_org_vars" ]]; then
    while IFS= read -r var; do
      local vname vvalue vvis
      vname="$(echo  "$var" | jq -r '.name')"
      vvalue="$(echo "$var" | jq -r '.value')"
      vvis="$(echo   "$var" | jq -r '.visibility // "all"')"
      if [[ "$vvis" == "selected" ]]; then
        warn "  Org variable '$vname': visibility=selected — setting visibility=all in target (repo list cannot be mapped; restrict manually if needed)"
        vvis="all"
      fi
      _upsert_org_variable "$vname" "$vvalue" "$vvis" "$tgt_org_vars"
      pause 0.2
    done < <(echo "$org_vars" | jq -c '.[]' 2>/dev/null || true)
  fi

  log "Applying repo-level variables..."
  while IFS= read -r repo_name; do
    [[ -z "$repo_name" ]] && continue
    if [[ -n "$excluded_repos" ]] && echo "$excluded_repos" | grep -qx "$repo_name" 2>/dev/null; then
      log "  Skipping excluded repo: $repo_name"; continue
    fi
    local repo_vars rv_count
    repo_vars="$(echo "$repo_vars_map" | jq -c --arg r "$repo_name" '.[$r] // []')"
    rv_count="$(echo "$repo_vars" | jq 'length' 2>/dev/null || echo 0)"
    [[ "$rv_count" -eq 0 ]] && continue
    log "  $repo_name: $rv_count variables"

    # H6 FIX: same out-of-band fetch + skip-on-error as the org path above.
    local _tgt_repo_raw tgt_repo_vars
    if _tgt_repo_raw="$(gh api "repos/$TARGET_ORG/$repo_name/actions/variables?per_page=100" --paginate 2>/dev/null)"; then
      tgt_repo_vars="$(printf '%s' "$_tgt_repo_raw" | jq -rs '[.[] | select(type == "object") | select(has("variables")) | .variables[] | select(type == "object") | .name]' 2>/dev/null || echo '[]')"
    else
      warn "  Could not list existing variables in $TARGET_ORG/$repo_name (404/scope?) — skipping to avoid duplicates"
      tgt_repo_vars=""
    fi

    if [[ -n "$tgt_repo_vars" ]]; then
      while IFS= read -r var; do
        local vname vvalue
        vname="$(echo  "$var" | jq -r '.name')"
        vvalue="$(echo "$var" | jq -r '.value')"
        _upsert_repo_variable "$repo_name" "$vname" "$vvalue" "$tgt_repo_vars"
        pause 0.2
      done < <(echo "$repo_vars" | jq -c '.[]' 2>/dev/null || true)
    fi
    pause 0.3
  done < <(echo "$repo_vars_map" | jq -r 'keys[]' 2>/dev/null || true)

  state_update_stats "$STATE_FILE"

  local total synced failed
  total="$(jq '.stats.total'   "$STATE_FILE")"
  synced="$(jq '.stats.synced' "$STATE_FILE")"
  failed="$(jq '.stats.failed' "$STATE_FILE")"
  log "Stage 13 complete — total=$total synced=$synced failed=$failed"

  if [[ "$DRY_RUN" -eq 0 ]]; then
    commit_state "mirror: state after stage 13 (mirror-actions-variables) [skip ci]"
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
      2>/dev/null)" || result='FAILED'
    [[ "$result" == "FAILED" ]] && { warn "  Failed to update org variable '$vname'"; status="failed"; } || \
      ok "  Updated org variable '$vname'"
  else
    local result
    result="$(gh api "orgs/$TARGET_ORG/actions/variables" \
      --method POST \
      -f name="$vname" -f value="$vvalue" -f visibility="$vvis" \
      2>/dev/null)" || result='FAILED'
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
      2>/dev/null)" || result='FAILED'
    [[ "$result" == "FAILED" ]] && { warn "  Failed to update variable '$vname' in $repo_name"; status="failed"; } || \
      ok "  Updated variable '$vname' in $repo_name"
  else
    local result
    result="$(gh api "repos/$TARGET_ORG/$repo_name/actions/variables" \
      --method POST \
      -f name="$vname" -f value="$vvalue" \
      2>/dev/null)" || result='FAILED'
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
