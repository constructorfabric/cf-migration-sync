#!/usr/bin/env bash
# mirror/stages/06-mirror-prs.sh
# Mirror CLOSED/MERGED PRs from source repos to target repos as issues.
# Open PRs are live dev work — skipped intentionally.
# State file: state/prs/<repo-name>.yaml
#
# Usage:
#   SOURCE_ORG=cyberfabric TARGET_ORG=constructorfabric \
#   GH_TOKEN=xxx GH_TOKEN_SOURCE=xxx \
#   ./mirror/stages/06-mirror-prs.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

TARGET_ORG="${TARGET_ORG:-constructorfabric}"
STATE_DIR="$REPO_ROOT/state/prs"

# ---------------------------------------------------------------------------
main() {
  check_dry_run "$@"
  preflight

  log "Stage 06 — mirror-prs starting"
  mkdir -p "$STATE_DIR"

  log "Fetching source repos from $SOURCE_ORG..."
  local repos
  repos="$(gh_paginate ghsrc "orgs/$SOURCE_ORG/repos")"
  local total_repos
  total_repos="$(echo "$repos" | jq 'length')"
  log "Found $total_repos repos in $SOURCE_ORG"

  local repo_idx=0

  while IFS= read -r repo; do
    local repo_name
    repo_name="$(echo "$repo" | jq -r '.name')"

    repo_idx=$((repo_idx + 1))
    log "[$repo_idx/$total_repos] Processing PRs for $repo_name..."

    _mirror_repo_prs "$repo_name"
    pause 0.5

  done < <(echo "$repos" | jq -c '.[]')

  log "Stage 06 complete"

  if [[ "$DRY_RUN" -eq 0 ]]; then
    commit_state "mirror: state after stage 06 (mirror-prs) [skip ci]"
  fi
}

# ---------------------------------------------------------------------------
_mirror_repo_prs() {
  local repo_name="$1"
  local state_file="$STATE_DIR/$repo_name.yaml"

  state_init "$state_file" "06-mirror-prs"

  # Fetch closed PRs from source (all pages — repos can have thousands)
  log "  Fetching closed PRs from $SOURCE_ORG/$repo_name..."
  local prs
  prs="$(ghsrc api \
    "repos/$SOURCE_ORG/$repo_name/pulls?state=closed&per_page=100" \
    --paginate 2>/dev/null | jq -s 'add // []' || echo '[]')"

  local total_prs
  total_prs="$(echo "$prs" | jq 'length')"
  log "  Found $total_prs closed PRs in $repo_name"

  if [[ "$total_prs" -eq 0 ]]; then
    return 0
  fi

  # Check existing target issues for idempotency (all pages)
  local tgt_issues
  tgt_issues="$(gh api \
    "repos/$TARGET_ORG/$repo_name/issues?state=all&per_page=100" \
    --paginate 2>/dev/null | jq -s 'add // []' || echo '[]')"

  local processed=0
  local new_count=0
  local skip_count=0
  local failed_count=0

  while IFS= read -r pr; do
    local pr_number
    pr_number="$(echo "$pr" | jq -r '.number')"
    local pr_title
    pr_title="$(echo "$pr" | jq -r '.title')"
    local pr_body
    pr_body="$(echo "$pr" | jq -r '.body // ""')"
    local pr_state
    pr_state="$(echo "$pr" | jq -r '.state')"
    local pr_merged
    pr_merged="$(echo "$pr" | jq -r '.merged_at // ""')"
    local pr_author
    pr_author="$(echo "$pr" | jq -r '.user.login // "unknown"')"
    local pr_created
    pr_created="$(echo "$pr" | jq -r '.created_at // ""')"
    local pr_url
    pr_url="https://github.com/$SOURCE_ORG/$repo_name/pull/$pr_number"

    processed=$((processed + 1))
    if (( processed % 25 == 0 )); then
      log "  Progress: $processed/$total_prs PRs..."
    fi

    # ---- Check idempotency via state -------------------------------------
    local already_status
    already_status="$(jq -r --argjson n "$pr_number" \
      '.items[] | select(.source_pr_number == $n) | .status // empty' \
      "$state_file" 2>/dev/null | head -1 || true)"

    if [[ "$already_status" == "mirrored" ]]; then
      skip_count=$((skip_count + 1))
      continue
    fi

    # ---- Check idempotency via marker in target --------------------------
    local marker="<!-- cf-mirror-pr: $SOURCE_ORG/$repo_name#$pr_number -->"
    local existing_target_number
    existing_target_number="$(echo "$tgt_issues" | jq -r \
      --arg marker "$marker" \
      '.[] | select(.body != null and (.body | contains($marker))) | .number' \
      2>/dev/null | head -1 || true)"

    if [[ -n "$existing_target_number" ]]; then
      log "  PR #$pr_number already mirrored as issue #$existing_target_number, updating state"
      _upsert_pr "$state_file" "$pr_number" "$pr_url" \
        "$existing_target_number" "$pr_title" "mirrored" "$(now)"
      skip_count=$((skip_count + 1))
      continue
    fi

    if dry_run_skip "create PR-as-issue for PR#$pr_number in $TARGET_ORG/$repo_name"; then
      new_count=$((new_count + 1))
      continue
    fi

    # ---- Build issue body -----------------------------------------------
    local pr_status_str="closed"
    if [[ -n "$pr_merged" && "$pr_merged" != "null" ]]; then
      pr_status_str="merged on $pr_merged"
    fi

    local issue_body
    issue_body="**Mirrored from:** $pr_url
**Original author:** @$pr_author
**Created:** $pr_created
**Status:** $pr_status_str

---

$pr_body

---
$marker"

    # ---- Create issue in target -----------------------------------------
    local issue_title="[PR #$pr_number] $pr_title"
    local payload
    payload="$(jq -n \
      --arg title "$issue_title" \
      --arg body  "$issue_body" \
      '{"title":$title,"body":$body}')"

    local create_result
    create_result="$(gh api "repos/$TARGET_ORG/$repo_name/issues" \
      --method POST \
      --input <(echo "$payload") \
      2>/dev/null || echo 'FAILED')"

    if [[ "$create_result" == "FAILED" ]]; then
      warn "  Failed to create issue for PR#$pr_number in $TARGET_ORG/$repo_name"
      _upsert_pr "$state_file" "$pr_number" "$pr_url" "" "$pr_title" "failed" ""
      failed_count=$((failed_count + 1))
      pause 0.3
      continue
    fi

    local tgt_issue_number
    tgt_issue_number="$(echo "$create_result" | jq -r '.number')"

    # Close the target issue (it's a historical PR)
    gh api "repos/$TARGET_ORG/$repo_name/issues/$tgt_issue_number" \
      --method PATCH \
      -f state="closed" \
      2>/dev/null || warn "  Failed to close issue #$tgt_issue_number"

    ok "  Mirrored PR #$pr_number -> issue #$tgt_issue_number in $TARGET_ORG/$repo_name"

    _upsert_pr "$state_file" "$pr_number" "$pr_url" \
      "$tgt_issue_number" "$pr_title" "mirrored" "$(now)"

    new_count=$((new_count + 1))
    pause 0.3

  done < <(echo "$prs" | jq -c '.[]')

  state_update_stats "$state_file"
  ok "  Done $repo_name: new=$new_count skipped=$skip_count failed=$failed_count"
}

# ---------------------------------------------------------------------------
_upsert_pr() {
  local state_file="$1"
  local src_pr_number="$2"
  local src_url="$3"
  local tgt_issue_number="$4"
  local title="$5"
  local status="$6"
  local mirrored_at="$7"

  local record
  record="$(jq -n \
    --argjson src_pr_num  "$src_pr_number" \
    --arg     src_url     "$src_url" \
    --argjson tgt_num     "${tgt_issue_number:-null}" \
    --arg     title       "[PR #$src_pr_number] $title" \
    --arg     status      "$status" \
    --arg     mat         "${mirrored_at:-}" \
    '{
      source_pr_number:   $src_pr_num,
      source_url:         $src_url,
      target_issue_number: $tgt_num,
      title:              $title,
      status:             $status,
      mirrored_at:        (if $mat == "" then null else $mat end)
    }')"

  local tmp
  tmp="$(mktemp)"
  jq --argjson sn "$src_pr_number" --argjson rec "$record" \
    'if (.items | map(select(.source_pr_number == $sn)) | length) > 0
     then .items = [.items[] | if .source_pr_number == $sn then $rec else . end]
     else .items += [$rec]
     end' \
    "$state_file" > "$tmp"
  mv "$tmp" "$state_file"
}

main "$@"
