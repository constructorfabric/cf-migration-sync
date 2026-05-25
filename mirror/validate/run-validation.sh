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

    local src_branches tgt_branches src_tags tgt_tags
    src_branches="$(ghsrc api "repos/$SOURCE_ORG/$repo_name/branches?per_page=100" \
      2>/dev/null | jq 'length' || echo 0)"
    tgt_branches="$(gh api "repos/$TARGET_ORG/$repo_name/branches?per_page=100" \
      2>/dev/null | jq 'length' || echo 0)"
    src_tags="$(ghsrc api "repos/$SOURCE_ORG/$repo_name/tags?per_page=100" \
      2>/dev/null | jq 'length' || echo 0)"
    tgt_tags="$(gh api "repos/$TARGET_ORG/$repo_name/tags?per_page=100" \
      2>/dev/null | jq 'length' || echo 0)"

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

    # Count source issues (excluding PRs)
    local sc
    sc="$(ghsrc api "repos/$SOURCE_ORG/$repo_name/issues?state=all&per_page=1" \
      2>/dev/null | jq 'if type=="array" then length else 0 end' || echo 0)"
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

    # Count closed source PRs
    local sc
    sc="$(ghsrc api "repos/$SOURCE_ORG/$repo_name/pulls?state=closed&per_page=1" \
      2>/dev/null | jq 'if type=="array" then length else 0 end' || echo 0)"
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

main "$@"
