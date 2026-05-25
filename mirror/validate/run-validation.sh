#!/usr/bin/env bash
# mirror/validate/run-validation.sh
# Run all validation checks and write a report to validation-reports/.
# Reports are append-only (never modified after creation).
#
# Usage:
#   SOURCE_ORG=cyberfabric TARGET_ORG=constructorfabric \
#   GH_TOKEN=xxx GH_TOKEN_SOURCE=xxx \
#   ./mirror/validate/run-validation.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

TARGET_ORG="${TARGET_ORG:-constructorfabric}"

REPORT_DIR="$REPO_ROOT/validation-reports"
STATE_DIR="$REPO_ROOT/state"

# ---------------------------------------------------------------------------
main() {
  preflight

  local ts
  ts="$(now)"
  local ts_file
  ts_file="$(echo "$ts" | sed 's/:/-/g; s/T/-/; s/Z/Z/')"
  local report_file="$REPORT_DIR/${ts_file}.yaml"

  mkdir -p "$REPORT_DIR"

  log "Validation starting at $ts"
  log "Source org: $SOURCE_ORG | Target org: $TARGET_ORG"
  log "Report will be written to: $report_file"

  local checks="[]"
  local total_checks=0
  local passed=0
  local failed=0
  local warnings=0

  # ---- Check 1: Members -------------------------------------------------
  log "Check 1: Members..."
  local c
  c="$(_check_members)"
  checks="$(echo "$checks" | jq --argjson c "$c" '. + [$c]')"
  _tally_check "$c"
  total_checks=$((total_checks + 1))

  # ---- Check 2: Repos ---------------------------------------------------
  log "Check 2: Repos..."
  c="$(_check_repos)"
  checks="$(echo "$checks" | jq --argjson c "$c" '. + [$c]')"
  _tally_check "$c"
  total_checks=$((total_checks + 1))

  # ---- Check 3: Git refs (sample) ---------------------------------------
  log "Check 3: Git refs (sample)..."
  c="$(_check_git_refs)"
  checks="$(echo "$checks" | jq --argjson c "$c" '. + [$c]')"
  _tally_check "$c"
  total_checks=$((total_checks + 1))

  # ---- Check 4: Org settings --------------------------------------------
  log "Check 4: Org settings..."
  c="$(_check_org_settings)"
  checks="$(echo "$checks" | jq --argjson c "$c" '. + [$c]')"
  _tally_check "$c"
  total_checks=$((total_checks + 1))

  # ---- Check 5: Labels --------------------------------------------------
  log "Check 5: Labels..."
  c="$(_check_labels)"
  checks="$(echo "$checks" | jq --argjson c "$c" '. + [$c]')"
  _tally_check "$c"
  total_checks=$((total_checks + 1))

  # ---- Check 6: Milestones ----------------------------------------------
  log "Check 6: Milestones..."
  c="$(_check_milestones)"
  checks="$(echo "$checks" | jq --argjson c "$c" '. + [$c]')"
  _tally_check "$c"
  total_checks=$((total_checks + 1))

  # ---- Check 7: Issues --------------------------------------------------
  log "Check 7: Issues..."
  c="$(_check_issues)"
  checks="$(echo "$checks" | jq --argjson c "$c" '. + [$c]')"
  _tally_check "$c"
  total_checks=$((total_checks + 1))

  # ---- Check 8: PRs -----------------------------------------------------
  log "Check 8: PRs..."
  c="$(_check_prs)"
  checks="$(echo "$checks" | jq --argjson c "$c" '. + [$c]')"
  _tally_check "$c"
  total_checks=$((total_checks + 1))

  # ---- Check 9: Assignees -----------------------------------------------
  log "Check 9: Assignees..."
  c="$(_check_assignees)"
  checks="$(echo "$checks" | jq --argjson c "$c" '. + [$c]')"
  _tally_check "$c"
  total_checks=$((total_checks + 1))

  # ---- Check 10: Manual items -------------------------------------------
  log "Check 10: Manual items..."
  c="$(_check_manual_items)"
  checks="$(echo "$checks" | jq --argjson c "$c" '. + [$c]')"
  _tally_check "$c"
  total_checks=$((total_checks + 1))

  # ---- Check 11: Teams --------------------------------------------------
  log "Check 11: Teams..."
  c="$(_check_teams)"
  checks="$(echo "$checks" | jq --argjson c "$c" '. + [$c]')"
  _tally_check "$c"
  total_checks=$((total_checks + 1))

  # ---- Check 12: Releases -----------------------------------------------
  log "Check 12: Releases..."
  c="$(_check_releases)"
  checks="$(echo "$checks" | jq --argjson c "$c" '. + [$c]')"
  _tally_check "$c"
  total_checks=$((total_checks + 1))

  # ---- Check 13: Branch protections ------------------------------------
  log "Check 13: Branch protections..."
  c="$(_check_branch_protections)"
  checks="$(echo "$checks" | jq --argjson c "$c" '. + [$c]')"
  _tally_check "$c"
  total_checks=$((total_checks + 1))

  # ---- Check 14: Actions variables -------------------------------------
  log "Check 14: Actions variables..."
  c="$(_check_actions_variables)"
  checks="$(echo "$checks" | jq --argjson c "$c" '. + [$c]')"
  _tally_check "$c"
  total_checks=$((total_checks + 1))

  # ---- Check 15: Outside collaborators --------------------------------
  log "Check 15: Outside collaborators..."
  c="$(_check_outside_collaborators)"
  checks="$(echo "$checks" | jq --argjson c "$c" '. + [$c]')"
  _tally_check "$c"
  total_checks=$((total_checks + 1))

  # ---- Check 16: Webhooks ---------------------------------------------
  log "Check 16: Webhooks..."
  c="$(_check_webhooks)"
  checks="$(echo "$checks" | jq --argjson c "$c" '. + [$c]')"
  _tally_check "$c"
  total_checks=$((total_checks + 1))

  # ---- Write report -----------------------------------------------------
  jq -n \
    --arg gen_at "$ts" \
    --arg src    "$SOURCE_ORG" \
    --arg tgt    "$TARGET_ORG" \
    --argjson total  "$total_checks" \
    --argjson pass   "$passed" \
    --argjson fail   "$failed" \
    --argjson warn   "$warnings" \
    --argjson checks "$checks" \
    '{
      generated_at: $gen_at,
      source_org:   $src,
      target_org:   $tgt,
      summary: {
        total_checks: $total,
        passed:       $pass,
        failed:       $fail,
        warnings:     $warn
      },
      checks: $checks
    }' > "$report_file"

  ok "Report written to $report_file"
  log "Summary: total=$total_checks passed=$passed failed=$failed warnings=$warnings"

  # Print a human-readable summary to stdout
  echo ""
  echo "=== Validation Report ==="
  echo "Generated: $ts"
  echo "Source: $SOURCE_ORG | Target: $TARGET_ORG"
  echo "Total: $total_checks | Passed: $passed | Failed: $failed | Warnings: $warnings"
  echo ""
  echo "$checks" | jq -r '.[] | "  [\(.status | ascii_upcase)] \(.name): \(.details)"'
  echo ""

  if [[ "$DRY_RUN" -eq 0 ]]; then
    commit_state "mirror: validation report $ts_file [skip ci]"
  fi

  # Exit with non-zero if any checks failed
  if [[ "$failed" -gt 0 ]]; then
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Tally helper — reads check JSON from stdin, updates counters
_check_status=""
_tally_check() {
  local check_json="$1"
  local status
  status="$(echo "$check_json" | jq -r '.status')"
  case "$status" in
    passed)   passed=$((passed + 1)) ;;
    failed)   failed=$((failed + 1)) ;;
    warning)  warnings=$((warnings + 1)) ;;
  esac
}

# ---------------------------------------------------------------------------
# Check 1: Members
_check_members() {
  local src_members tgt_members src_count tgt_count
  src_members="$(gh_paginate ghsrc "orgs/$SOURCE_ORG/members" 2>/dev/null || echo '[]')"
  tgt_members="$(gh_paginate gh   "orgs/$TARGET_ORG/members" 2>/dev/null || echo '[]')"

  src_count="$(echo "$src_members" | jq 'length')"
  tgt_count="$(echo "$tgt_members" | jq 'length')"

  local src_logins tgt_logins missing
  src_logins="$(echo "$src_members" | jq -r '[.[].login | ascii_downcase]')"
  tgt_logins="$(echo "$tgt_members" | jq -r '[.[].login | ascii_downcase]')"
  missing="$(echo "$src_logins $tgt_logins" | jq -s '.[0] - .[1]')"
  local missing_count
  missing_count="$(echo "$missing" | jq 'length')"

  local status="passed"
  local details="Source: $src_count, Target: $tgt_count"
  if [[ "$missing_count" -gt 0 ]]; then
    status="warning"
    details="$details — $missing_count members not yet in target (may be pending invitation)"
  fi

  jq -n \
    --arg name    "members" \
    --arg status  "$status" \
    --argjson sc  "$src_count" \
    --argjson tc  "$tgt_count" \
    --arg details "$details" \
    --argjson miss "$missing" \
    '{"name":$name,"status":$status,"source_count":$sc,"target_count":$tc,"details":$details,"missing":$miss}'
}

# ---------------------------------------------------------------------------
# Check 2: Repos
_check_repos() {
  local src_repos tgt_repos src_count tgt_count
  src_repos="$(gh_paginate ghsrc "orgs/$SOURCE_ORG/repos" 2>/dev/null || echo '[]')"
  tgt_repos="$(gh_paginate gh   "orgs/$TARGET_ORG/repos" 2>/dev/null || echo '[]')"

  src_count="$(echo "$src_repos" | jq 'length')"
  tgt_count="$(echo "$tgt_repos" | jq 'length')"

  local src_names tgt_names missing
  src_names="$(echo "$src_repos" | jq '[.[].name]')"
  tgt_names="$(echo "$tgt_repos" | jq '[.[].name]')"
  missing="$(echo "$src_names $tgt_names" | jq -s '.[0] - .[1]')"
  local missing_count
  missing_count="$(echo "$missing" | jq 'length')"

  local status="passed"
  local details="Source: $src_count, Target: $tgt_count"
  if [[ "$missing_count" -gt 0 ]]; then
    status="failed"
    details="$details — $missing_count repos missing in target"
  fi

  jq -n \
    --arg name    "repos" \
    --arg status  "$status" \
    --argjson sc  "$src_count" \
    --argjson tc  "$tgt_count" \
    --arg details "$details" \
    --argjson miss "$missing" \
    '{"name":$name,"status":$status,"source_count":$sc,"target_count":$tc,"details":$details,"missing":$miss}'
}

# ---------------------------------------------------------------------------
# Check 3: Git refs (sample 3-5 repos)
_check_git_refs() {
  local src_repos
  src_repos="$(gh_paginate ghsrc "orgs/$SOURCE_ORG/repos" 2>/dev/null || echo '[]')"

  # Pick up to 5 non-empty repos
  local sample_repos
  sample_repos="$(echo "$src_repos" | jq -r '
    [.[] | select(.size > 0)] | .[0:5] | .[].name
  ')"

  local details="Sampled repos:"
  local issues_found="[]"
  local all_ok=1

  while IFS= read -r repo_name; do
    [[ -z "$repo_name" ]] && continue

    # BUG-12 fix: use --paginate so the count isn't capped at 100 for large repos.
    local src_branches tgt_branches src_tags tgt_tags
    src_branches="$(ghsrc api "repos/$SOURCE_ORG/$repo_name/branches?per_page=100" \
      --paginate 2>/dev/null | jq -s 'add // [] | length' || echo 0)"
    tgt_branches="$(gh api "repos/$TARGET_ORG/$repo_name/branches?per_page=100" \
      --paginate 2>/dev/null | jq -s 'add // [] | length' || echo 0)"
    src_tags="$(ghsrc api "repos/$SOURCE_ORG/$repo_name/tags?per_page=100" \
      --paginate 2>/dev/null | jq -s 'add // [] | length' || echo 0)"
    tgt_tags="$(gh api "repos/$TARGET_ORG/$repo_name/tags?per_page=100" \
      --paginate 2>/dev/null | jq -s 'add // [] | length' || echo 0)"

    details="$details $repo_name(branches:${src_branches}vs${tgt_branches},tags:${src_tags}vs${tgt_tags})"

    if [[ "$src_branches" != "$tgt_branches" || "$src_tags" != "$tgt_tags" ]]; then
      all_ok=0
      issues_found="$(echo "$issues_found" | jq \
        --arg r "$repo_name" \
        --argjson sb "$src_branches" --argjson tb "$tgt_branches" \
        --argjson st "$src_tags" --argjson tt "$tgt_tags" \
        '. + [{"repo":$r,"src_branches":$sb,"tgt_branches":$tb,"src_tags":$st,"tgt_tags":$tt}]')"
    fi

    pause 0.3
  done <<< "$sample_repos"

  local status="passed"
  if [[ "$all_ok" -eq 0 ]]; then
    status="warning"
  fi

  jq -n \
    --arg name    "git_refs_sample" \
    --arg status  "$status" \
    --arg details "$details" \
    --argjson miss "$issues_found" \
    '{"name":$name,"status":$status,"details":$details,"mismatches":$miss}'
}

# ---------------------------------------------------------------------------
# Check 4: Org settings
_check_org_settings() {
  local src_org tgt_org
  src_org="$(ghsrc api "orgs/$SOURCE_ORG" 2>/dev/null || echo '{}')"
  tgt_org="$(gh api "orgs/$TARGET_ORG" 2>/dev/null || echo '{}')"

  local src_perm tgt_perm
  src_perm="$(echo "$src_org" | jq -r '.default_repository_permission // "read"')"
  tgt_perm="$(echo "$tgt_org" | jq -r '.default_repository_permission // "read"')"

  local src_fork tgt_fork
  src_fork="$(echo "$src_org" | jq -r '.members_can_fork_private_repositories // false')"
  tgt_fork="$(echo "$tgt_org" | jq -r '.members_can_fork_private_repositories // false')"

  local status="passed"
  local details="default_repo_perm: src=$src_perm tgt=$tgt_perm; fork_private: src=$src_fork tgt=$tgt_fork"
  local diffs="[]"

  if [[ "$src_perm" != "$tgt_perm" ]]; then
    status="warning"
    diffs="$(echo "$diffs" | jq \
      --arg k "default_repository_permission" \
      --arg s "$src_perm" --arg t "$tgt_perm" \
      '. + [{"key":$k,"source":$s,"target":$t}]')"
  fi
  if [[ "$src_fork" != "$tgt_fork" ]]; then
    status="warning"
    diffs="$(echo "$diffs" | jq \
      --arg k "members_can_fork_private_repositories" \
      --arg s "$src_fork" --arg t "$tgt_fork" \
      '. + [{"key":$k,"source":$s,"target":$t}]')"
  fi

  jq -n \
    --arg name    "org_settings" \
    --arg status  "$status" \
    --arg details "$details" \
    --argjson diffs "$diffs" \
    '{"name":$name,"status":$status,"details":$details,"diffs":$diffs}'
}

# ---------------------------------------------------------------------------
# Check 5: Labels
_check_labels() {
  local repos
  repos="$(gh_paginate ghsrc "orgs/$SOURCE_ORG/repos" 2>/dev/null || echo '[]')"

  local total_src=0 total_tgt=0 repos_with_issues=0 mismatches="[]"

  while IFS= read -r repo_name; do
    [[ -z "$repo_name" ]] && continue

    local has_issues
    has_issues="$(echo "$repos" | jq -r --arg n "$repo_name" \
      '.[] | select(.name == $n) | .has_issues' 2>/dev/null || echo "false")"
    [[ "$has_issues" != "true" ]] && continue

    repos_with_issues=$((repos_with_issues + 1))
    local sc tc
    sc="$(ghsrc api "repos/$SOURCE_ORG/$repo_name/labels?per_page=100" \
      2>/dev/null | jq 'length' || echo 0)"
    tc="$(gh api "repos/$TARGET_ORG/$repo_name/labels?per_page=100" \
      2>/dev/null | jq 'length' || echo 0)"

    total_src=$((total_src + sc))
    total_tgt=$((total_tgt + tc))

    if [[ "$sc" != "$tc" ]]; then
      mismatches="$(echo "$mismatches" | jq \
        --arg r "$repo_name" --argjson sc "$sc" --argjson tc "$tc" \
        '. + [{"repo":$r,"source":$sc,"target":$tc}]')"
    fi

    pause 0.3
  done < <(echo "$repos" | jq -r '.[].name')

  local mismatch_count
  mismatch_count="$(echo "$mismatches" | jq 'length')"
  local status="passed"
  if [[ "$mismatch_count" -gt 0 ]]; then
    status="warning"
  fi

  jq -n \
    --arg name    "labels" \
    --arg status  "$status" \
    --argjson sc  "$total_src" \
    --argjson tc  "$total_tgt" \
    --argjson repos "$repos_with_issues" \
    --argjson miss  "$mismatches" \
    '{"name":$name,"status":$status,"source_count":$sc,"target_count":$tc,
      "repos_checked":$repos,"details":"Label counts per repo","mismatches":$miss}'
}

# ---------------------------------------------------------------------------
# Check 6: Milestones
_check_milestones() {
  local repos
  repos="$(gh_paginate ghsrc "orgs/$SOURCE_ORG/repos" 2>/dev/null || echo '[]')"

  local total_src=0 total_tgt=0 mismatches="[]"

  while IFS= read -r repo_name; do
    [[ -z "$repo_name" ]] && continue
    local sc tc
    sc="$(ghsrc api "repos/$SOURCE_ORG/$repo_name/milestones?per_page=100&state=all" \
      2>/dev/null | jq 'length' || echo 0)"
    tc="$(gh api "repos/$TARGET_ORG/$repo_name/milestones?per_page=100&state=all" \
      2>/dev/null | jq 'length' || echo 0)"

    total_src=$((total_src + sc))
    total_tgt=$((total_tgt + tc))

    if [[ "$sc" != "$tc" ]]; then
      mismatches="$(echo "$mismatches" | jq \
        --arg r "$repo_name" --argjson sc "$sc" --argjson tc "$tc" \
        '. + [{"repo":$r,"source":$sc,"target":$tc}]')"
    fi

    pause 0.3
  done < <(echo "$repos" | jq -r '.[].name')

  local mismatch_count
  mismatch_count="$(echo "$mismatches" | jq 'length')"
  local status="passed"
  [[ "$mismatch_count" -gt 0 ]] && status="warning"

  jq -n \
    --arg name    "milestones" \
    --arg status  "$status" \
    --argjson sc  "$total_src" \
    --argjson tc  "$total_tgt" \
    --argjson miss "$mismatches" \
    '{"name":$name,"status":$status,"source_count":$sc,"target_count":$tc,
      "details":"Milestone counts per repo","mismatches":$miss}'
}

# ---------------------------------------------------------------------------
# Check 7: Issues
_check_issues() {
  local state_issues_dir="$STATE_DIR/issues"
  local total_src=0 total_mirrored=0 total_failed=0

  if [[ ! -d "$state_issues_dir" ]]; then
    jq -n '{"name":"issues","status":"warning","details":"No issues state directory found","source_count":0,"target_count":0}'
    return 0
  fi

  local repos
  repos="$(gh_paginate ghsrc "orgs/$SOURCE_ORG/repos" 2>/dev/null || echo '[]')"

  while IFS= read -r repo_name; do
    [[ -z "$repo_name" ]] && continue

    # BUG-06 fix: per_page=1 + jq length always returns 0 or 1.
    # GitHub Search API returns total_count for issue counts without full pagination.
    local sc
    sc="$(ghsrc api "search/issues?q=repo:$SOURCE_ORG/$repo_name+is:issue&per_page=1" \
      2>/dev/null | jq '.total_count // 0' || echo 0)"
    total_src=$((total_src + sc))

    # Count from state file
    local state_file="$state_issues_dir/$repo_name.yaml"
    if [[ -f "$state_file" ]]; then
      local mirrored failed
      mirrored="$(jq '[.items[] | select(.status=="mirrored")] | length' "$state_file" 2>/dev/null || echo 0)"
      failed="$(jq '[.items[] | select(.status=="failed")] | length' "$state_file" 2>/dev/null || echo 0)"
      total_mirrored=$((total_mirrored + mirrored))
      total_failed=$((total_failed + failed))
    fi

    pause 0.2
  done < <(echo "$repos" | jq -r '.[].name')

  local status="passed"
  if [[ "$total_failed" -gt 0 ]]; then
    status="warning"
  fi

  jq -n \
    --arg name    "issues" \
    --arg status  "$status" \
    --argjson sc  "$total_src" \
    --argjson tc  "$total_mirrored" \
    --argjson fail "$total_failed" \
    '{"name":$name,"status":$status,"source_count":$sc,"target_count":$tc,
      "failed_count":$fail,"details":"Issues mirrored vs source count"}'
}

# ---------------------------------------------------------------------------
# Check 8: PRs
_check_prs() {
  local state_prs_dir="$STATE_DIR/prs"
  local total_src=0 total_mirrored=0 total_failed=0

  if [[ ! -d "$state_prs_dir" ]]; then
    jq -n '{"name":"prs","status":"warning","details":"No PRs state directory found","source_count":0,"target_count":0}'
    return 0
  fi

  local repos
  repos="$(gh_paginate ghsrc "orgs/$SOURCE_ORG/repos" 2>/dev/null || echo '[]')"

  while IFS= read -r repo_name; do
    [[ -z "$repo_name" ]] && continue

    # BUG-06 fix: per_page=1 + jq length always returns 0 or 1.
    local sc
    sc="$(ghsrc api "search/issues?q=repo:$SOURCE_ORG/$repo_name+is:pr+is:closed&per_page=1" \
      2>/dev/null | jq '.total_count // 0' || echo 0)"
    total_src=$((total_src + sc))

    local state_file="$state_prs_dir/$repo_name.yaml"
    if [[ -f "$state_file" ]]; then
      local mirrored failed
      mirrored="$(jq '[.items[] | select(.status=="mirrored")] | length' "$state_file" 2>/dev/null || echo 0)"
      failed="$(jq '[.items[] | select(.status=="failed")] | length' "$state_file" 2>/dev/null || echo 0)"
      total_mirrored=$((total_mirrored + mirrored))
      total_failed=$((total_failed + failed))
    fi

    pause 0.2
  done < <(echo "$repos" | jq -r '.[].name')

  local status="passed"
  [[ "$total_failed" -gt 0 ]] && status="warning"

  jq -n \
    --arg name    "prs" \
    --arg status  "$status" \
    --argjson sc  "$total_src" \
    --argjson tc  "$total_mirrored" \
    --argjson fail "$total_failed" \
    '{"name":$name,"status":$status,"source_count":$sc,"target_count":$tc,
      "failed_count":$fail,"details":"Closed PRs mirrored as issues vs source count"}'
}

# ---------------------------------------------------------------------------
# Check 9: Assignees
_check_assignees() {
  local state_issues_dir="$STATE_DIR/issues"
  local pending_count=0

  if [[ ! -d "$state_issues_dir" ]]; then
    jq -n '{"name":"assignees","status":"passed","details":"No issues state found","pending_count":0}'
    return 0
  fi

  for state_file in "$state_issues_dir"/*.yaml; do
    [[ -f "$state_file" ]] || continue
    local pc
    pc="$(jq '[.items[] | select(.assignees_status=="pending" and (.assignees|length)>0)] | length' \
      "$state_file" 2>/dev/null || echo 0)"
    pending_count=$((pending_count + pc))
  done

  local status="passed"
  [[ "$pending_count" -gt 0 ]] && status="warning"

  jq -n \
    --arg name    "assignees" \
    --arg status  "$status" \
    --argjson pc  "$pending_count" \
    '{"name":$name,"status":$status,"pending_count":$pc,
      "details":"Issues with assignees not yet applied"}'
}

# ---------------------------------------------------------------------------
# Check 10: Manual items
_check_manual_items() {
  local other_obj_file="$STATE_DIR/other-objects.yaml"

  if [[ ! -f "$other_obj_file" ]]; then
    jq -n '{"name":"manual_items","status":"warning","details":"other-objects.yaml not found","pending_count":0,"items":[]}'
    return 0
  fi

  local items
  items="$(jq '[.items[] | select(.manual_action_required==true)]' "$other_obj_file" 2>/dev/null || echo '[]')"
  local count
  count="$(echo "$items" | jq 'length')"

  local status="warning"
  [[ "$count" -eq 0 ]] && status="passed"

  local summary
  summary="$(echo "$items" | jq '[group_by(.type) | .[] | {type:.[0].type, count:length}]')"

  jq -n \
    --arg name    "manual_items" \
    --arg status  "$status" \
    --argjson count "$count" \
    --argjson summary "$summary" \
    --argjson items "$items" \
    '{"name":$name,"status":$status,"pending_count":$count,
      "details":"Objects requiring manual action","summary":$summary,"items":$items}'
}

# ---------------------------------------------------------------------------
# Check 11: Teams
_check_teams() {
  local src_count tgt_count
  src_count="$(gh_paginate ghsrc "orgs/$SOURCE_ORG/teams" 2>/dev/null | jq 'length' || echo 0)"
  tgt_count="$(gh_paginate gh   "orgs/$TARGET_ORG/teams" 2>/dev/null | jq 'length' || echo 0)"

  local state_file="$STATE_DIR/teams.yaml"
  local failed_count=0
  if [[ -f "$state_file" ]]; then
    failed_count="$(jq '[.items[] | select(.status=="failed")] | length' \
      "$state_file" 2>/dev/null || echo 0)"
  fi

  local missing
  missing="$(( src_count - tgt_count ))"
  [[ "$missing" -lt 0 ]] && missing=0

  local status="passed"
  if [[ "$missing" -gt 0 || "$failed_count" -gt 0 ]]; then status="warning"; fi

  jq -n \
    --arg name   "teams" \
    --arg status "$status" \
    --argjson sc "$src_count" \
    --argjson tc "$tgt_count" \
    --argjson miss "$missing" \
    --argjson fail "$failed_count" \
    '{"name":$name,"status":$status,"source_count":$sc,"target_count":$tc,
      "missing":$miss,"failed_count":$fail,"details":"Team count: source vs target"}'
}

# ---------------------------------------------------------------------------
# Check 12: Releases
_check_releases() {
  local state_dir="$STATE_DIR/releases"

  if [[ ! -d "$state_dir" ]]; then
    jq -n '{"name":"releases","status":"warning","details":"No releases state directory — stage 10 not yet run","mirrored":0,"failed":0}'
    return 0
  fi

  local total_mirrored=0 total_failed=0 repos_with_releases=0

  for sf in "$state_dir"/*.yaml; do
    [[ -f "$sf" ]] || continue
    repos_with_releases=$((repos_with_releases + 1))
    local m f
    m="$(jq '[.items[] | select(.status=="mirrored")] | length' "$sf" 2>/dev/null || echo 0)"
    f="$(jq '[.items[] | select(.status=="failed")]   | length' "$sf" 2>/dev/null || echo 0)"
    total_mirrored=$((total_mirrored + m))
    total_failed=$((total_failed + f))
  done

  local status="passed"
  [[ "$total_failed" -gt 0 ]] && status="warning"

  jq -n \
    --arg name   "releases" \
    --arg status "$status" \
    --argjson repos "$repos_with_releases" \
    --argjson mir  "$total_mirrored" \
    --argjson fail "$total_failed" \
    '{"name":$name,"status":$status,"repos_with_releases":$repos,"mirrored":$mir,
      "failed":$fail,"details":"Releases mirrored per state files (stage 10)"}'
}

# ---------------------------------------------------------------------------
# Check 13: Branch protections
_check_branch_protections() {
  local state_dir="$STATE_DIR/branch-protections"

  if [[ ! -d "$state_dir" ]]; then
    jq -n '{"name":"branch_protections","status":"warning","details":"No branch-protections state — stage 11 not yet run","synced":0,"failed":0}'
    return 0
  fi

  local total_synced=0 total_failed=0 repos_checked=0

  for sf in "$state_dir"/*.yaml; do
    [[ -f "$sf" ]] || continue
    repos_checked=$((repos_checked + 1))
    local s f
    s="$(jq '[.items[] | select(.status=="synced")] | length' "$sf" 2>/dev/null || echo 0)"
    f="$(jq '[.items[] | select(.status=="failed")] | length' "$sf" 2>/dev/null || echo 0)"
    total_synced=$((total_synced + s))
    total_failed=$((total_failed + f))
  done

  local status="passed"
  [[ "$total_failed" -gt 0 ]] && status="warning"

  jq -n \
    --arg name   "branch_protections" \
    --arg status "$status" \
    --argjson repos "$repos_checked" \
    --argjson sync "$total_synced" \
    --argjson fail "$total_failed" \
    '{"name":$name,"status":$status,"repos_checked":$repos,"synced":$sync,
      "failed":$fail,"details":"Rulesets and legacy branch protection rules (stage 11)"}'
}

# ---------------------------------------------------------------------------
# Check 14: Actions variables
_check_actions_variables() {
  local state_file="$STATE_DIR/actions-variables.yaml"

  if [[ ! -f "$state_file" ]]; then
    jq -n '{"name":"actions_variables","status":"warning","details":"No actions-variables state — stage 12 not yet run","synced":0,"failed":0}'
    return 0
  fi

  local synced failed
  synced="$(jq '[.items[] | select(.status=="synced")] | length' "$state_file" 2>/dev/null || echo 0)"
  failed="$(jq '[.items[] | select(.status=="failed")] | length' "$state_file" 2>/dev/null || echo 0)"

  # Cross-check: live org-level variable count on target
  local tgt_org_var_count
  tgt_org_var_count="$(gh api "orgs/$TARGET_ORG/actions/variables?per_page=1" \
    2>/dev/null | jq '.total_count // 0' || echo 0)"

  local src_org_var_count
  src_org_var_count="$(ghsrc api "orgs/$SOURCE_ORG/actions/variables?per_page=1" \
    2>/dev/null | jq '.total_count // 0' || echo 0)"

  local status="passed"
  [[ "$failed" -gt 0 ]] && status="warning"
  [[ "$src_org_var_count" -gt "$tgt_org_var_count" ]] && status="warning"

  jq -n \
    --arg name   "actions_variables" \
    --arg status "$status" \
    --argjson synced "$synced" \
    --argjson failed "$failed" \
    --argjson src_org "$src_org_var_count" \
    --argjson tgt_org "$tgt_org_var_count" \
    '{"name":$name,"status":$status,"state_synced":$synced,"state_failed":$failed,
      "source_org_vars":$src_org,"target_org_vars":$tgt_org,
      "details":"Actions variables org+repo level (stage 12); visibility=selected vars widened to all"}'
}

# ---------------------------------------------------------------------------
# Check 15: Outside collaborators
_check_outside_collaborators() {
  local state_dir="$STATE_DIR/outside-collaborators"

  if [[ ! -d "$state_dir" ]]; then
    jq -n '{"name":"outside_collaborators","status":"passed","details":"No outside-collaborators state — stage 13 not run or no collaborators found","synced":0,"failed":0}'
    return 0
  fi

  local total_synced=0 total_failed=0 repos_checked=0

  for sf in "$state_dir"/*.yaml; do
    [[ -f "$sf" ]] || continue
    repos_checked=$((repos_checked + 1))
    local s f
    s="$(jq '[.items[] | select(.status=="synced")]  | length' "$sf" 2>/dev/null || echo 0)"
    f="$(jq '[.items[] | select(.status=="failed")]  | length' "$sf" 2>/dev/null || echo 0)"
    total_synced=$((total_synced + s))
    total_failed=$((total_failed + f))
  done

  local status="passed"
  [[ "$total_failed" -gt 0 ]] && status="warning"

  jq -n \
    --arg name   "outside_collaborators" \
    --arg status "$status" \
    --argjson repos "$repos_checked" \
    --argjson sync "$total_synced" \
    --argjson fail "$total_failed" \
    '{"name":$name,"status":$status,"repos_checked":$repos,"synced":$sync,
      "failed":$fail,"details":"Per-repo outside collaborators (stage 13)"}'
}

# ---------------------------------------------------------------------------
# Check 16: Webhooks
_check_webhooks() {
  local other_obj_file="$STATE_DIR/other-objects.yaml"

  if [[ ! -f "$other_obj_file" ]]; then
    jq -n '{"name":"webhooks","status":"warning","details":"other-objects state not found — stage 08 not yet run","total":0}'
    return 0
  fi

  local total_wh created_no_secret failed_wh
  total_wh="$(jq '[.items[] | select(.type == "org_webhook" or .type == "repo_webhook")] | length' \
    "$other_obj_file" 2>/dev/null || echo 0)"
  created_no_secret="$(jq '[.items[] | select(
      (.type == "org_webhook" or .type == "repo_webhook") and
      .status == "created_no_secret")] | length' \
    "$other_obj_file" 2>/dev/null || echo 0)"
  failed_wh="$(jq '[.items[] | select(
      (.type == "org_webhook" or .type == "repo_webhook") and
      .status == "failed")] | length' \
    "$other_obj_file" 2>/dev/null || echo 0)"

  # Warn if any webhooks are pending (need secret) or failed
  local status="passed"
  [[ "$failed_wh" -gt 0 ]] && status="warning"
  [[ "$created_no_secret" -gt 0 ]] && status="warning"   # needs manual secret

  jq -n \
    --arg name   "webhooks" \
    --arg status "$status" \
    --argjson total   "$total_wh" \
    --argjson created "$created_no_secret" \
    --argjson failed  "$failed_wh" \
    '{"name":$name,"status":$status,"total":$total,"created_no_secret":$created,"failed":$failed,
      "details":"Webhook structure created; secrets must be set manually for created_no_secret entries"}'
}

main "$@"
