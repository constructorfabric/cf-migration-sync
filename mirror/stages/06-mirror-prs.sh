#!/usr/bin/env bash
# mirror/stages/06-mirror-prs.sh
# Mirror PRs from source repos to target repos.
#
# Strategy:
#   OPEN PRs  — NOT created in target (live dev work; hard to keep in sync).
#               Inventoried in state with status=skipped_open for visibility.
#   CLOSED PRs — Created as CLOSED ISSUES in target with:
#                  • Attribution header in body (original author, source URL, dates)
#                  • All discussion comments mirrored with attribution headers
#                  • All PR review bodies mirrored as comments
#                  • All inline review comments mirrored as comments with file/line context
#
# Why not create actual PRs?  The API requires source branches to exist in
# target.  For merged PRs the feature branch is typically deleted; for stale
# closed PRs it may be gone too.  Issues are reliable; branches are not.
#
# Attribution note: GitHub API does not allow setting the author of an issue
# or comment — it will always appear as the token owner.  Attribution is
# preserved in the body/comment text, not the metadata field.
#
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

  # ---- Load excluded repos from config ------------------------------------
  local excluded_repos
  excluded_repos="$(jq -r '.stage_06_mirror_prs.exclude_repos[] // empty' \
    "$MIRROR_CONFIG" 2>/dev/null || true)"
  if [[ -n "$excluded_repos" ]]; then
    log "Excluded repos: $(echo "$excluded_repos" | tr '\n' ' ')"
  fi

  local repo_idx=0

  while IFS= read -r repo; do
    local repo_name
    repo_name="$(echo "$repo" | jq -r '.name')"

    repo_idx=$((repo_idx + 1))

    if [[ -n "$excluded_repos" ]] && echo "$excluded_repos" | grep -qx "$repo_name" 2>/dev/null; then
      log "[$repo_idx/$total_repos] Skipping excluded repo: $repo_name"
      continue
    fi

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

  # ---- 1. Inventory open PRs (NOT mirrored — live dev work) ---------------
  log "  Fetching open PRs from $SOURCE_ORG/$repo_name (inventory only)..."
  local open_prs
  open_prs="$(ghsrc api \
    "repos/$SOURCE_ORG/$repo_name/pulls?state=open&per_page=100" \
    --paginate 2>/dev/null | jq -s 'add // []' || echo '[]')"

  local open_count
  open_count="$(echo "$open_prs" | jq 'length')"
  if [[ "$open_count" -gt 0 ]]; then
    log "  Found $open_count open PRs — recording as skipped_open (not created in target)"
    while IFS= read -r pr; do
      local pr_number pr_title pr_author pr_url
      pr_number="$(echo "$pr" | jq -r '.number')"
      pr_title="$(echo  "$pr" | jq -r '.title')"
      pr_author="$(echo "$pr" | jq -r '.user.login // "unknown"')"
      pr_url="https://github.com/$SOURCE_ORG/$repo_name/pull/$pr_number"

      # Only insert if not already tracked (closed version takes precedence)
      local already_status
      already_status="$(jq -r --argjson n "$pr_number" \
        '.items[] | select(.source_pr_number == $n) | .status // empty' \
        "$state_file" 2>/dev/null | head -1 || true)"
      if [[ -z "$already_status" ]]; then
        _upsert_pr "$state_file" "$pr_number" "$pr_url" "" \
          "$pr_title" "skipped_open" "" "$pr_author" "open"
      fi
    done < <(echo "$open_prs" | jq -c '.[]' 2>/dev/null || true)
  fi

  # ---- 2. Fetch closed PRs from source ------------------------------------
  log "  Fetching closed PRs from $SOURCE_ORG/$repo_name..."
  local prs
  prs="$(ghsrc api \
    "repos/$SOURCE_ORG/$repo_name/pulls?state=closed&per_page=100" \
    --paginate 2>/dev/null | jq -s 'add // []' || echo '[]')"

  local total_prs
  total_prs="$(echo "$prs" | jq 'length')"
  log "  Found $total_prs closed PRs in $repo_name"

  if [[ "$total_prs" -eq 0 ]]; then
    state_update_stats "$state_file"
    return 0
  fi

  # Pre-fetch existing target issues for idempotency marker check
  local tgt_issues
  tgt_issues="$(gh api \
    "repos/$TARGET_ORG/$repo_name/issues?state=all&per_page=100" \
    --paginate 2>/dev/null | jq -s 'add // []' || echo '[]')"

  local processed=0 new_count=0 skip_count=0 failed_count=0

  while IFS= read -r pr; do
    local pr_number pr_title pr_body pr_state pr_merged pr_author pr_created pr_url
    pr_number="$(echo "$pr" | jq -r '.number')"
    pr_title="$(echo  "$pr" | jq -r '.title')"
    pr_body="$(echo   "$pr" | jq -r '.body // ""')"
    pr_state="$(echo  "$pr" | jq -r '.state')"
    pr_merged="$(echo "$pr" | jq -r '.merged_at // ""')"
    pr_author="$(echo "$pr" | jq -r '.user.login // "unknown"')"
    pr_created="$(echo "$pr" | jq -r '.created_at // ""')"
    pr_url="https://github.com/$SOURCE_ORG/$repo_name/pull/$pr_number"

    processed=$((processed + 1))
    if (( processed % 25 == 0 )); then
      log "  Progress: $processed/$total_prs PRs..."
    fi

    # ---- Idempotency: split on body vs comments (same pattern as stage 05) --
    local already_status
    already_status="$(jq -r --argjson n "$pr_number" \
      '.items[] | select(.source_pr_number == $n) | .status // empty' \
      "$state_file" 2>/dev/null | head -1 || true)"

    if [[ "$already_status" == "mirrored" ]]; then
      local already_comments_status tgt_issue_in_state
      already_comments_status="$(jq -r --argjson n "$pr_number" \
        '.items[] | select(.source_pr_number == $n) | .comments_status // empty' \
        "$state_file" 2>/dev/null | head -1 || true)"
      if [[ "$already_comments_status" == "done" ]]; then
        skip_count=$((skip_count + 1))
        continue
      fi
      # Body mirrored but comments not yet done — resume
      tgt_issue_in_state="$(jq -r --argjson n "$pr_number" \
        '.items[] | select(.source_pr_number == $n) | .target_issue_number // empty' \
        "$state_file" 2>/dev/null | head -1 || true)"
      if [[ -n "$tgt_issue_in_state" && "$tgt_issue_in_state" != "null" ]]; then
        log "  PR #$pr_number body already mirrored — completing comment sync..."
        _mirror_pr_comments "$repo_name" "$pr_number" "$tgt_issue_in_state" "$state_file"
      fi
      skip_count=$((skip_count + 1))
      continue
    fi

    # ---- Idempotency via body marker in target ---------------------------
    local marker="<!-- cf-mirror-pr: $SOURCE_ORG/$repo_name#$pr_number -->"
    local existing_target_number
    existing_target_number="$(echo "$tgt_issues" | jq -r \
      --arg marker "$marker" \
      '.[] | select(.body != null and (.body | contains($marker))) | .number' \
      2>/dev/null | head -1 || true)"

    if [[ -n "$existing_target_number" ]]; then
      log "  PR #$pr_number already mirrored as issue #$existing_target_number — syncing state+comments"
      _upsert_pr "$state_file" "$pr_number" "$pr_url" \
        "$existing_target_number" "$pr_title" "mirrored" "$(now)" "$pr_author" "$pr_state"
      _mirror_pr_comments "$repo_name" "$pr_number" "$existing_target_number" "$state_file"
      skip_count=$((skip_count + 1))
      continue
    fi

    if dry_run_skip "create PR-as-issue for PR#$pr_number in $TARGET_ORG/$repo_name"; then
      new_count=$((new_count + 1))
      continue
    fi

    # ---- Build issue body with attribution header -----------------------
    local pr_status_str="closed (not merged)"
    if [[ -n "$pr_merged" && "$pr_merged" != "null" ]]; then
      pr_status_str="merged on $pr_merged"
    fi

    local issue_body
    issue_body="> **Mirrored PR** | Original: $pr_url
> **Author:** @$pr_author | **Opened:** $pr_created | **Status:** $pr_status_str
> *GitHub API does not allow setting PR author or timestamps — attribution preserved here.*

---

${pr_body}

---
${marker}"

    # ---- Create issue in target -----------------------------------------
    local payload
    payload="$(jq -n \
      --arg title "[PR #$pr_number] $pr_title" \
      --arg body  "$issue_body" \
      '{"title":$title,"body":$body}')"

    local create_result
    create_result="$(gh api "repos/$TARGET_ORG/$repo_name/issues" \
      --method POST \
      --input <(echo "$payload") \
      2>/dev/null || echo 'FAILED')"

    if [[ "$create_result" == "FAILED" ]]; then
      warn "  Failed to create issue for PR #$pr_number in $TARGET_ORG/$repo_name"
      _upsert_pr "$state_file" "$pr_number" "$pr_url" "" \
        "$pr_title" "failed" "" "$pr_author" "$pr_state"
      failed_count=$((failed_count + 1))
      pause 0.3
      continue
    fi

    local tgt_issue_number
    tgt_issue_number="$(echo "$create_result" | jq -rs '.[0].number // empty' 2>/dev/null || true)"

    # Close the target issue immediately (historical PR)
    gh api "repos/$TARGET_ORG/$repo_name/issues/$tgt_issue_number" \
      --method PATCH \
      -f state="closed" \
      2>/dev/null || warn "  Failed to close issue #$tgt_issue_number"
    pause 0.2

    ok "  Mirrored PR #$pr_number -> issue #$tgt_issue_number in $TARGET_ORG/$repo_name"

    _upsert_pr "$state_file" "$pr_number" "$pr_url" \
      "$tgt_issue_number" "$pr_title" "mirrored" "$(now)" "$pr_author" "$pr_state"

    # Mirror all comments (discussion + reviews + inline)
    _mirror_pr_comments "$repo_name" "$pr_number" "$tgt_issue_number" "$state_file"

    new_count=$((new_count + 1))
    pause 0.3

  done < <(echo "$prs" | jq -c '.[]' 2>/dev/null || true)

  state_update_stats "$state_file"
  ok "  Done $repo_name: new=$new_count skipped=$skip_count failed=$failed_count"
}

# ---------------------------------------------------------------------------
# _mirror_pr_comments
# Mirrors three types of PR content onto the target issue:
#   1. Discussion comments  (GET /issues/{n}/comments)
#   2. Review-level bodies  (GET /pulls/{n}/reviews — only non-empty bodies)
#   3. Inline review comments (GET /pulls/{n}/comments — with file/line context)
# All are posted as issue comments with attribution headers.
# Idempotency: state field comments_status="done" skips re-runs.
# ---------------------------------------------------------------------------
_mirror_pr_comments() {
  local repo_name="$1"
  local src_pr_number="$2"
  local tgt_issue_number="$3"
  local state_file="$4"

  # ---- Fetch all three comment types from source --------------------------
  local issue_comments
  issue_comments="$(ghsrc api \
    "repos/$SOURCE_ORG/$repo_name/issues/$src_pr_number/comments?per_page=100" \
    --paginate 2>/dev/null | jq -s 'add // []' || echo '[]')"

  local review_comments
  review_comments="$(ghsrc api \
    "repos/$SOURCE_ORG/$repo_name/pulls/$src_pr_number/comments?per_page=100" \
    --paginate 2>/dev/null | jq -s 'add // []' || echo '[]')"

  # Reviews: only those with a non-empty body (e.g. "LGTM" messages)
  local pr_reviews
  pr_reviews="$(ghsrc api \
    "repos/$SOURCE_ORG/$repo_name/pulls/$src_pr_number/reviews?per_page=100" \
    --paginate 2>/dev/null | \
    jq -s 'add // [] | map(select(.body != null and .body != ""))' || echo '[]')"

  local ic_total rc_total rv_total
  ic_total="$(echo "$issue_comments"  | jq 'length' 2>/dev/null || echo 0)"
  rc_total="$(echo "$review_comments" | jq 'length' 2>/dev/null || echo 0)"
  rv_total="$(echo "$pr_reviews"      | jq 'length' 2>/dev/null || echo 0)"

  local total_comments=$(( ic_total + rc_total + rv_total ))

  if [[ "$total_comments" -eq 0 ]]; then
    _update_pr_comments_status "$state_file" "$src_pr_number" "done" 0
    return 0
  fi

  log "  PR #$src_pr_number: mirroring $ic_total discussion + $rv_total review-bodies + $rc_total inline-review comments..."

  local mirrored=0

  # -- 1. Discussion comments -----------------------------------------------
  while IFS= read -r c; do
    local c_id c_author c_created c_body c_marker c_full_body c_payload c_result
    c_id="$(echo      "$c" | jq -r '.id')"
    c_author="$(echo  "$c" | jq -r '.user.login // "unknown"')"
    c_created="$(echo "$c" | jq -r '.created_at // ""')"
    c_body="$(echo    "$c" | jq -r '.body // ""')"
    c_marker="<!-- cf-mirror-pr-comment: $SOURCE_ORG/$repo_name#$src_pr_number/$c_id -->"

    c_full_body="**@${c_author}** commented on ${c_created}:

---

${c_body}

${c_marker}"

    c_payload="$(jq -n --arg body "$c_full_body" '{"body":$body}')"
    c_result="$(gh api "repos/$TARGET_ORG/$repo_name/issues/$tgt_issue_number/comments" \
      --method POST --input <(echo "$c_payload") \
      2>/dev/null || echo 'FAILED')"
    if [[ "$c_result" == "FAILED" ]]; then
      warn "  Failed to mirror discussion comment $c_id on PR #$src_pr_number"
    else
      mirrored=$((mirrored + 1))
    fi
    pause 0.2
  done < <(echo "$issue_comments" | jq -c '.[]' 2>/dev/null || true)

  # -- 2. Review-level bodies (Approved / Changes requested + message) ------
  while IFS= read -r rv; do
    local rv_id rv_author rv_state rv_submitted rv_body rv_marker rv_full_body rv_payload rv_result
    rv_id="$(echo        "$rv" | jq -r '.id')"
    rv_author="$(echo    "$rv" | jq -r '.user.login // "unknown"')"
    rv_state="$(echo     "$rv" | jq -r '.state // "COMMENTED"')"
    rv_submitted="$(echo "$rv" | jq -r '.submitted_at // ""')"
    rv_body="$(echo      "$rv" | jq -r '.body // ""')"
    rv_marker="<!-- cf-mirror-pr-review: $SOURCE_ORG/$repo_name#$src_pr_number/$rv_id -->"

    rv_full_body="**@${rv_author}** submitted review **${rv_state}** on ${rv_submitted}:

---

${rv_body}

${rv_marker}"

    rv_payload="$(jq -n --arg body "$rv_full_body" '{"body":$body}')"
    rv_result="$(gh api "repos/$TARGET_ORG/$repo_name/issues/$tgt_issue_number/comments" \
      --method POST --input <(echo "$rv_payload") \
      2>/dev/null || echo 'FAILED')"
    if [[ "$rv_result" == "FAILED" ]]; then
      warn "  Failed to mirror review body $rv_id on PR #$src_pr_number"
    else
      mirrored=$((mirrored + 1))
    fi
    pause 0.2
  done < <(echo "$pr_reviews" | jq -c '.[]' 2>/dev/null || true)

  # -- 3. Inline review comments (with file + line context) -----------------
  while IFS= read -r rc; do
    local rc_id rc_author rc_created rc_body rc_path rc_line rc_marker rc_full_body rc_payload rc_result
    rc_id="$(echo      "$rc" | jq -r '.id')"
    rc_author="$(echo  "$rc" | jq -r '.user.login // "unknown"')"
    rc_created="$(echo "$rc" | jq -r '.created_at // ""')"
    rc_body="$(echo    "$rc" | jq -r '.body // ""')"
    rc_path="$(echo    "$rc" | jq -r '.path // "(unknown file)"')"
    rc_line="$(echo    "$rc" | jq -r '(.line // .original_line) | tostring' 2>/dev/null || echo '?')"
    rc_marker="<!-- cf-mirror-pr-review-inline: $SOURCE_ORG/$repo_name#$src_pr_number/$rc_id -->"

    rc_full_body="**@${rc_author}** reviewed \`${rc_path}\` line ${rc_line} on ${rc_created}:

---

${rc_body}

${rc_marker}"

    rc_payload="$(jq -n --arg body "$rc_full_body" '{"body":$body}')"
    rc_result="$(gh api "repos/$TARGET_ORG/$repo_name/issues/$tgt_issue_number/comments" \
      --method POST --input <(echo "$rc_payload") \
      2>/dev/null || echo 'FAILED')"
    if [[ "$rc_result" == "FAILED" ]]; then
      warn "  Failed to mirror inline review comment $rc_id on PR #$src_pr_number"
    else
      mirrored=$((mirrored + 1))
    fi
    pause 0.2
  done < <(echo "$review_comments" | jq -c '.[]' 2>/dev/null || true)

  _update_pr_comments_status "$state_file" "$src_pr_number" "done" "$mirrored"
  ok "  Mirrored $mirrored/$total_comments comments for PR #$src_pr_number"
}

# ---------------------------------------------------------------------------
_update_pr_comments_status() {
  local state_file="$1"
  local src_pr_number="$2"
  local status="$3"
  local count="$4"

  local tmp
  tmp="$(mktemp)"
  jq --argjson sn "$src_pr_number" --arg st "$status" --argjson count "$count" \
    '.items = [.items[] |
      if .source_pr_number == $sn
      then .comments_status = $st | .comments_mirrored = $count
      else .
      end]' \
    "$state_file" > "$tmp"
  mv "$tmp" "$state_file"
}

# ---------------------------------------------------------------------------
_upsert_pr() {
  local state_file="$1"
  local src_pr_number="$2"
  local src_url="$3"
  local tgt_issue_number="$4"
  local title="$5"
  local status="$6"
  local mirrored_at="${7:-}"
  local pr_author="${8:-}"
  local pr_state="${9:-closed}"

  local record
  record="$(jq -n \
    --argjson src_pr_num   "$src_pr_number" \
    --arg     src_url      "$src_url" \
    --arg     pr_state     "$pr_state" \
    --arg     pr_author    "$pr_author" \
    --argjson tgt_num      "${tgt_issue_number:-null}" \
    --arg     title        "[PR #$src_pr_number] $title" \
    --arg     status       "$status" \
    --arg     mat          "${mirrored_at:-}" \
    '{
      source_pr_number:    $src_pr_num,
      source_url:          $src_url,
      source_state:        $pr_state,
      source_author:       $pr_author,
      target_issue_number: $tgt_num,
      title:               $title,
      status:              $status,
      mirrored_at:         (if $mat == "" then null else $mat end),
      comments_status:     "none",
      comments_mirrored:   0
    }')"

  local tmp
  tmp="$(mktemp)"
  # Preserve comments_status/comments_mirrored across re-runs
  jq --argjson sn "$src_pr_number" --argjson rec "$record" \
    'if (.items | map(select(.source_pr_number == $sn)) | length) > 0
     then .items = [.items[] | if .source_pr_number == $sn then
       . as $old | $rec |
       .comments_status   = ($old.comments_status   // "none") |
       .comments_mirrored = ($old.comments_mirrored // 0)
     else . end]
     else .items += [$rec]
     end' \
    "$state_file" > "$tmp"
  mv "$tmp" "$state_file"
}

main "$@"
