#!/usr/bin/env bash
# mirror/stages/06-mirror-prs.sh
# Mirror PRs from source repos to target repos.
#
# Strategy:
#   OPEN PRs  — Created as real open PRs in target if the head branch exists.
#               Recorded as skipped_open if the branch is missing.
#   CLOSED PRs — Created as closed PRs in target if head branch exists, which
#                  preserves linked commits and file diffs. Falls back to a
#                  closed issue when the branch is gone. In both cases:
#                  • Attribution header in body (original author, source URL, dates)
#                  • All discussion comments mirrored with attribution headers
#                  • All PR review bodies mirrored as comments
#                  • All inline review comments mirrored as comments with file/line context
#
# Why not always create real PRs?  The API requires the head branch to exist in
# target.  For merged PRs the feature branch is often deleted; issues are the
# reliable fallback for those cases.
#
# Attribution note: GitHub API does not allow setting the author of an issue
# or comment — it will always appear as the token owner.  Attribution is
# preserved in the body/comment text, not the metadata field.
#
# State file: state/prs/<repo-name>.yaml
#
# Usage:
#   SOURCE_ORG=... TARGET_ORG=... GH_TOKEN=xxx GH_TOKEN_SOURCE=xxx \
#   ./mirror/stages/06-mirror-prs.sh [--dry-run] [--repo REPO] [--start-after-pr N]
#
# --repo REPO           Process only this repository (skip all others).
# --start-after-pr N   In the closed-PR loop, fast-forward past all PRs with
#                       number > N.  Use this to resume after a rate-limit stop:
#                       if mirroring stalled at PR #1894, pass --start-after-pr 1894
#                       and the script jumps straight to #1893 and below.
#                       PRs already recorded as "mirrored" in the state file are
#                       still skipped by the normal idempotency check, so this flag
#                       is purely a fast-forward optimisation — it does not bypass
#                       idempotency, it just avoids reading the state file for every
#                       PR the user knows was already done.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

TARGET_ORG="${TARGET_ORG:-constructorfabric}"
STATE_DIR="$REPO_ROOT/state/prs"

# ---------------------------------------------------------------------------
# _encode_at_mentions — replace @username with &#64;username in piped text,
# skipping fenced code blocks and inline code spans, to prevent GitHub from
# sending notification emails for @mentions in mirrored content.
# Usage: encoded="$(echo "$body" | _encode_at_mentions)"
_encode_at_mentions() {
  python3 -c '
import re, sys

def encode_line(line):
    # Split on inline code spans to avoid encoding @mentions inside them
    parts = re.split(r"(`[^`\n]*`)", line)
    out = []
    for p in parts:
        if p.startswith("`"):
            out.append(p)
        else:
            out.append(re.sub(r"@([a-zA-Z0-9][-a-zA-Z0-9]*)", r"&#64;\1", p))
    return "".join(out)

lines = sys.stdin.read().split("\n")
in_fence = False
result = []
for line in lines:
    s = line.strip()
    if s.startswith("```") or s.startswith("~~~"):
        in_fence = not in_fence
        result.append(line)
        continue
    if in_fence:
        result.append(line)
        continue
    result.append(encode_line(line))
sys.stdout.write("\n".join(result))
'
}

# ---------------------------------------------------------------------------
# _gh_err_hint — extract a short (≤100 char) reason string from a failed
# gh api response body so callers can log it before overwriting the variable.
# Returns empty string when the body is not parseable JSON.
_gh_err_hint() {
  printf '%s' "$1" | jq -r '
    if .message then .message
    elif (.errors // [] | length) > 0 then (.errors[0].message // .errors[0].code // "unknown")
    else empty
    end' 2>/dev/null | cut -c1-100 || true
}

# ---------------------------------------------------------------------------
main() {
  # Parse our custom flags before passing the remainder to check_dry_run.
  local start_after_pr="" only_repo=""
  local passthrough_args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --start-after-pr) start_after_pr="$2"; shift 2 ;;
      --repo)           only_repo="$2";       shift 2 ;;
      *)                passthrough_args+=("$1"); shift ;;
    esac
  done

  check_dry_run "${passthrough_args[@]+"${passthrough_args[@]}"}"
  preflight

  log "Stage 06 — mirror-prs starting"
  [[ -n "$only_repo"       ]] && log "  Single-repo mode: $only_repo"
  [[ -n "$start_after_pr"  ]] && log "  Resume point: skipping closed PRs with number > $start_after_pr"
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

  # ---- Load per-repo resume points from config ----------------------------
  # resume_after_pr is a JSON object: { "repo-name": PR_NUMBER, ... }
  # CLI --start-after-pr overrides the config value for the targeted repo.
  local resume_map
  resume_map="$(jq -r '.stage_06_mirror_prs.resume_after_pr // {}' \
    "$MIRROR_CONFIG" 2>/dev/null || echo '{}')"

  local repo_idx=0

  while IFS= read -r repo; do
    local repo_name
    repo_name="$(echo "$repo" | jq -r '.name')"

    repo_idx=$((repo_idx + 1))

    # Single-repo filter
    if [[ -n "$only_repo" && "$repo_name" != "$only_repo" ]]; then
      continue
    fi

    if [[ -n "$excluded_repos" ]] && echo "$excluded_repos" | grep -qx "$repo_name" 2>/dev/null; then
      log "[$repo_idx/$total_repos] Skipping excluded repo: $repo_name"
      continue
    fi

    # Resolve effective resume point: CLI flag > config map > none
    local effective_resume="$start_after_pr"
    if [[ -z "$effective_resume" ]]; then
      effective_resume="$(echo "$resume_map" | \
        jq -r --arg r "$repo_name" 'if has($r) and (.[$r] | . != null and . != 0) then .[$r] | tostring else empty end' \
        2>/dev/null || true)"
    fi

    log "[$repo_idx/$total_repos] Processing PRs for $repo_name${effective_resume:+ (resume after PR #$effective_resume)}..."
    _mirror_repo_prs "$repo_name" "$effective_resume"
    pause 0.5

  done < <(echo "$repos" | jq -c '.[]')

  log "Stage 06 complete"

  if [[ "$DRY_RUN" -eq 0 ]]; then
    commit_state "mirror: state after stage 06 (mirror-prs) [skip ci]"
  fi
}

# ---------------------------------------------------------------------------
# _create_or_update_branch — ensure a branch in the target repo points to a
# specific SHA. Creates it if absent, force-updates it if it already exists
# (e.g. from a previous interrupted run).
_create_or_update_branch() {
  local repo_name="$1" branch="$2" sha="$3"
  # Try to create first.
  gh api "repos/$TARGET_ORG/$repo_name/git/refs" \
    --method POST \
    -f "ref=refs/heads/$branch" \
    -f "sha=$sha" \
    &>/dev/null && return 0
  # Branch already exists — force-update it to the correct SHA.
  gh api "repos/$TARGET_ORG/$repo_name/git/refs/heads/$branch" \
    --method PATCH \
    -f "sha=$sha" \
    -F "force=true" \
    &>/dev/null && return 0
  return 1
}

# ---------------------------------------------------------------------------
_mirror_repo_prs() {
  local repo_name="$1"
  local start_after_pr="${2:-}"   # fast-forward: skip closed PRs with number > this
  local state_file="$STATE_DIR/$repo_name.yaml"

  state_init "$state_file" "06-mirror-prs"

  # ---- Pre-fetch target data used by both open + closed PR loops ----------
  # Issues endpoint returns both issues and PRs — used for idempotency markers.
  log "  Pre-fetching existing target issues/PRs for $repo_name..."
  local tgt_issues
  tgt_issues="$(gh api \
    "repos/$TARGET_ORG/$repo_name/issues?state=all&per_page=100" \
    --paginate 2>/dev/null | \
    jq -rs '[.[] | select(type=="array") | .[] | select(type=="object")]')" || tgt_issues='[]'

  # Branch list with tip SHAs — one API call instead of one per PR.
  # SHA is needed to verify the branch tip matches pr.head.sha exactly.
  local tgt_branches
  tgt_branches="$(gh api \
    "repos/$TARGET_ORG/$repo_name/branches?per_page=100" \
    --paginate 2>/dev/null | \
    jq -rs '[.[] | select(type=="array") | .[] | select(type=="object") | {name: .name, sha: .commit.sha}]')" || tgt_branches='[]'

  # ---- 1. Open PRs — create as real PRs where head branch exists ----------
  log "  Fetching open PRs from $SOURCE_ORG/$repo_name..."
  local open_prs
  open_prs="$(ghsrc api \
    "repos/$SOURCE_ORG/$repo_name/pulls?state=open&per_page=100" \
    --paginate 2>/dev/null | \
    jq -rs '[.[] | select(type=="array") | .[] | select(type=="object")]')" || open_prs='[]'

  local open_count
  open_count="$(echo "$open_prs" | jq -r 'if type=="array" then length else 0 end' 2>/dev/null || echo 0)"
  log "  Found $open_count open PRs in $repo_name"

  if [[ "$open_count" -gt 0 ]]; then
    while IFS= read -r pr; do
      local pr_number pr_title pr_body pr_author pr_created pr_url pr_head_ref pr_base_ref
      pr_number="$(echo   "$pr" | jq -r '.number')"
      pr_title="$(echo    "$pr" | jq -r '.title')"
      pr_body="$(echo     "$pr" | jq -r '.body // ""')"
      pr_author="$(echo   "$pr" | jq -r '.user.login // "unknown"')"
      pr_created="$(echo  "$pr" | jq -r '.created_at // ""')"
      pr_head_ref="$(echo "$pr" | jq -r '.head.ref // ""')"
      pr_base_ref="$(echo "$pr" | jq -r '.base.ref // "main"')"
      pr_url="https://github.com/$SOURCE_ORG/$repo_name/pull/$pr_number"

      # Idempotency: already fully mirrored
      local already_status
      already_status="$(jq -r --argjson n "$pr_number" \
        '.items[] | select(.source_pr_number == $n) | .status // empty' \
        "$state_file" 2>/dev/null | head -1 || true)"

      if [[ "$already_status" == "mirrored" ]]; then
        local already_comments_status tgt_in_state
        already_comments_status="$(jq -r --argjson n "$pr_number" \
          '.items[] | select(.source_pr_number == $n) | .comments_status // empty' \
          "$state_file" 2>/dev/null | head -1 || true)"
        tgt_in_state="$(jq -r --argjson n "$pr_number" \
          '.items[] | select(.source_pr_number == $n) | .target_issue_number // empty' \
          "$state_file" 2>/dev/null | head -1 || true)"

        if [[ "${CONTINUOUS:-false}" == "true" && -n "$tgt_in_state" && "$tgt_in_state" != "null" ]]; then
          # Full reconcile for open PRs: title, body, labels, and all comments
          # (add new ones, update edited ones).
          _reconcile_pr "$repo_name" "$pr" "$pr_number" "$tgt_in_state" "$state_file"
          continue
        fi

        if [[ "$already_comments_status" == "done" ]]; then
          continue
        fi
        if [[ -n "$tgt_in_state" && "$tgt_in_state" != "null" ]]; then
          log "  Open PR #$pr_number body already mirrored — completing comment sync..."
          _mirror_pr_comments "$repo_name" "$pr_number" "$tgt_in_state" "$state_file"
        fi
        continue
      fi

      # Idempotency: check for existing marker in target
      local marker="<!-- cf-mirror-pr: $SOURCE_ORG/$repo_name#$pr_number -->"
      local existing_target_number
      existing_target_number="$(echo "$tgt_issues" | jq -r \
        --arg marker "$marker" \
        '.[] | select(.body != null and (.body | contains($marker))) | .number' \
        2>/dev/null | head -1 || true)"
      if [[ -n "$existing_target_number" ]]; then
        log "  Open PR #$pr_number already mirrored as #$existing_target_number — syncing state+comments"
        _upsert_pr "$state_file" "$pr_number" "$pr_url" \
          "$existing_target_number" "$pr_title" "mirrored" "$(now)" "$pr_author" "open"
        _mirror_pr_comments "$repo_name" "$pr_number" "$existing_target_number" "$state_file"
        continue
      fi

      if dry_run_skip "create real PR for open PR#$pr_number in $TARGET_ORG/$repo_name"; then
        continue
      fi

      # O(1) branch existence check against pre-fetched list (name only for open PRs)
      local branch_in_target=0
      if [[ -n "$pr_head_ref" ]] && \
         echo "$tgt_branches" | jq -e --arg ref "$pr_head_ref" \
           'map(select(.name == $ref)) | length > 0' &>/dev/null 2>&1; then
        branch_in_target=1
      fi

      if [[ $branch_in_target -eq 0 ]]; then
        log "  Open PR #$pr_number: head branch '$pr_head_ref' not in target — skipping"
        _upsert_pr "$state_file" "$pr_number" "$pr_url" "" \
          "$pr_title" "skipped_open" "" "$pr_author" "open"
        continue
      fi

      # Build body with attribution + marker, then create real PR
      pr_body="$(echo "$pr_body" | _encode_at_mentions)"
      local open_pr_body
      open_pr_body="> 🔗 **Mirrored PR** [$SOURCE_ORG/$repo_name#$pr_number]($pr_url) | **Author:** $pr_author | **Opened:** $pr_created | **Status:** open
> *GitHub API does not allow setting PR author or timestamps — attribution preserved here.*

---

${pr_body}

---
${marker}"

      # Use printf|jq pipe to avoid ARG_MAX on large bodies
      local open_payload
      open_payload="$(printf '%s' "$open_pr_body" | jq -Rs \
        --arg title "$pr_title" \
        --arg head  "$pr_head_ref" \
        --arg base  "$pr_base_ref" \
        '{"title":$title,"body":.,"head":$head,"base":$base}')"

      local open_result open_err=""
      open_result="$(gh api "repos/$TARGET_ORG/$repo_name/pulls" \
        --method POST \
        --input <(echo "$open_payload") \
        2>/dev/null)" || {
        open_err="$(_gh_err_hint "$open_result")"; open_result="FAILED"
      }

      if [[ "$open_result" == "FAILED" ]]; then
        warn "  Failed to create real PR for open PR #$pr_number${open_err:+ — $open_err} — recording as skipped"
        _upsert_pr "$state_file" "$pr_number" "$pr_url" "" \
          "$pr_title" "skipped_open" "" "$pr_author" "open"
        continue
      fi

      local tgt_open_pr_number
      tgt_open_pr_number="$(echo "$open_result" | jq -rs '.[0].number // empty' 2>/dev/null || true)"

      if [[ -z "$tgt_open_pr_number" || "$tgt_open_pr_number" == "null" ]]; then
        warn "  Open PR #$pr_number: API did not return a valid PR number — recording as skipped"
        _upsert_pr "$state_file" "$pr_number" "$pr_url" "" \
          "$pr_title" "skipped_open" "" "$pr_author" "open"
        continue
      fi

      pause 1.5   # rate-limit cooldown after POST /pulls
      ok "  Mirrored open PR #$pr_number -> PR #$tgt_open_pr_number in $TARGET_ORG/$repo_name"
      _upsert_pr "$state_file" "$pr_number" "$pr_url" \
        "$tgt_open_pr_number" "$pr_title" "mirrored" "$(now)" "$pr_author" "open"
      _mirror_pr_comments "$repo_name" "$pr_number" "$tgt_open_pr_number" "$state_file"
      pause 1.0   # rate-limit buffer between PRs

    done < <(echo "$open_prs" | jq -c '.[]' 2>/dev/null || true)
  fi

  # ---- 2. Closed PRs — real PR if branch exists, else issue ---------------
  log "  Fetching closed PRs from $SOURCE_ORG/$repo_name..."
  local prs
  prs="$(ghsrc api \
    "repos/$SOURCE_ORG/$repo_name/pulls?state=closed&per_page=100" \
    --paginate 2>/dev/null | \
    jq -rs '[.[] | select(type=="array") | .[] | select(type=="object")]')" || prs='[]'

  local total_prs
  total_prs="$(echo "$prs" | jq -r 'if type=="array" then length else 0 end' 2>/dev/null || echo 0)"
  log "  Found $total_prs closed PRs in $repo_name"

  if [[ "$total_prs" -eq 0 ]]; then
    state_update_stats "$state_file"
    return 0
  fi

  local processed=0 new_count=0 skip_count=0 failed_count=0

  while IFS= read -r pr; do
    local pr_number pr_title pr_body pr_state pr_merged pr_author pr_created pr_url
    local pr_head_ref pr_head_sha pr_base_ref
    pr_number="$(echo    "$pr" | jq -r '.number')"
    pr_title="$(echo     "$pr" | jq -r '.title')"
    pr_body="$(echo      "$pr" | jq -r '.body // ""')"
    pr_state="$(echo     "$pr" | jq -r '.state')"
    pr_merged="$(echo    "$pr" | jq -r '.merged_at // ""')"
    pr_author="$(echo    "$pr" | jq -r '.user.login // "unknown"')"
    pr_created="$(echo   "$pr" | jq -r '.created_at // ""')"
    pr_head_ref="$(echo  "$pr" | jq -r '.head.ref // ""')"
    pr_head_sha="$(echo  "$pr" | jq -r '.head.sha // ""')"
    pr_base_ref="$(echo  "$pr" | jq -r '.base.ref // "main"')"
    pr_url="https://github.com/$SOURCE_ORG/$repo_name/pull/$pr_number"

    processed=$((processed + 1))
    if (( processed % 25 == 0 )); then
      log "  Progress: $processed/$total_prs PRs..."
    fi

    # ---- Fast-forward skip (--start-after-pr) --------------------------------
    # PRs are returned newest-first; anything above the resume point was already
    # handled in a previous run.  This avoids reading the state file for every
    # one of them, making the initial scan O(1) per skipped PR instead of O(n).
    if [[ -n "$start_after_pr" ]] && (( pr_number > start_after_pr )); then
      skip_count=$((skip_count + 1))
      continue
    fi

    # ---- Idempotency: body vs comments split --------------------------------
    local already_status
    already_status="$(jq -r --argjson n "$pr_number" \
      '.items[] | select(.source_pr_number == $n) | .status // empty' \
      "$state_file" 2>/dev/null | head -1 || true)"

    if [[ "$already_status" == "mirrored" ]]; then
      local already_comments_status tgt_issue_in_state
      already_comments_status="$(jq -r --argjson n "$pr_number" \
        '.items[] | select(.source_pr_number == $n) | .comments_status // empty' \
        "$state_file" 2>/dev/null | head -1 || true)"
      tgt_issue_in_state="$(jq -r --argjson n "$pr_number" \
        '.items[] | select(.source_pr_number == $n) | .target_issue_number // empty' \
        "$state_file" 2>/dev/null | head -1 || true)"

      if [[ "${CONTINUOUS:-false}" == "true" && -n "$tgt_issue_in_state" && "$tgt_issue_in_state" != "null" ]]; then
        # Full reconcile if PR just transitioned open→closed (body status line needs
        # updating, title/body may have changed before merge).
        # Lightweight (close + new comments) if it was already closed last run.
        local state_file_pr_state
        state_file_pr_state="$(jq -r --argjson n "$pr_number" \
          '.items[] | select(.source_pr_number == $n) | .source_state // empty' \
          "$state_file" 2>/dev/null | head -1 || true)"

        if [[ "$state_file_pr_state" == "open" ]]; then
          _reconcile_pr "$repo_name" "$pr" "$pr_number" "$tgt_issue_in_state" "$state_file"
        else
          gh api "repos/$TARGET_ORG/$repo_name/issues/$tgt_issue_in_state" \
            --method PATCH -f state="closed" 2>/dev/null || true
          pause 1.0
          _mirror_pr_comments "$repo_name" "$pr_number" "$tgt_issue_in_state" "$state_file"
        fi
        skip_count=$((skip_count + 1))
        continue
      fi

      if [[ "$already_comments_status" == "done" ]]; then
        skip_count=$((skip_count + 1))
        continue
      fi
      if [[ -n "$tgt_issue_in_state" && "$tgt_issue_in_state" != "null" ]]; then
        log "  PR #$pr_number body already mirrored — completing comment sync..."
        _mirror_pr_comments "$repo_name" "$pr_number" "$tgt_issue_in_state" "$state_file"
      fi
      skip_count=$((skip_count + 1))
      continue
    fi

    # ---- Idempotency via body marker in target ------------------------------
    local marker="<!-- cf-mirror-pr: $SOURCE_ORG/$repo_name#$pr_number -->"
    local existing_target_number
    existing_target_number="$(echo "$tgt_issues" | jq -r \
      --arg marker "$marker" \
      '.[] | select(.body != null and (.body | contains($marker))) | .number' \
      2>/dev/null | head -1 || true)"

    if [[ -n "$existing_target_number" ]]; then
      log "  PR #$pr_number already mirrored as #$existing_target_number — syncing state+comments"
      _upsert_pr "$state_file" "$pr_number" "$pr_url" \
        "$existing_target_number" "$pr_title" "mirrored" "$(now)" "$pr_author" "$pr_state"
      # Idempotent close — source PR is closed/merged; target may still be open
      # if a previous run was interrupted after creation but before the close step.
      gh api "repos/$TARGET_ORG/$repo_name/issues/$existing_target_number" \
        --method PATCH \
        -f state="closed" \
        2>/dev/null || warn "  Failed to close #$existing_target_number in $TARGET_ORG/$repo_name"
      _mirror_pr_comments "$repo_name" "$pr_number" "$existing_target_number" "$state_file"
      skip_count=$((skip_count + 1))
      continue
    fi

    if dry_run_skip "create PR-as-issue for PR#$pr_number in $TARGET_ORG/$repo_name"; then
      new_count=$((new_count + 1))
      continue
    fi

    # ---- Build attribution body ---------------------------------------------
    local pr_status_str="closed (not merged)"
    if [[ -n "$pr_merged" && "$pr_merged" != "null" ]]; then
      pr_status_str="merged on $pr_merged"
    fi

    pr_body="$(echo "$pr_body" | _encode_at_mentions)"

    local issue_body
    issue_body="> 🔗 **Mirrored PR** [$SOURCE_ORG/$repo_name#$pr_number]($pr_url) | **Author:** $pr_author | **Opened:** $pr_created | **Status:** $pr_status_str
> *GitHub API does not allow setting PR author or timestamps — attribution preserved here.*

---

${pr_body}

---
${marker}"

    # ---- Determine the head ref to use for a real PR -----------------------
    # We must point to exactly pr_head_sha so the commit list matches the source PR.
    #
    # Case A: head branch tip == pr_head_sha → use the branch directly.
    # Case B: tip diverged or branch deleted → create a temp branch at pr_head_sha,
    #         create+close the PR, then delete the temp branch.  Commits remain
    #         visible in closed PRs even after the branch is deleted.
    local tgt_issue_number="" used_pr_api=0 head_for_pr="" created_temp_branch=0

    if [[ -n "$pr_head_sha" ]]; then
      # Case A: branch exists with exact tip SHA
      if echo "$tgt_branches" | jq -e \
           --arg ref "$pr_head_ref" --arg sha "$pr_head_sha" \
           'map(select(.name == $ref and .sha == $sha)) | length > 0' &>/dev/null 2>&1; then
        head_for_pr="$pr_head_ref"
      else
        # Case B: SHA exists in target (git objects were pushed) but branch tip
        # diverged or branch was deleted — pin a temp branch at the exact commit.
        local temp_branch="cf-mirror-pr-$pr_number"
        if _create_or_update_branch "$repo_name" "$temp_branch" "$pr_head_sha"; then
          head_for_pr="$temp_branch"
          created_temp_branch=1
        else
          warn "  PR #$pr_number: could not create temp branch '$temp_branch' at $pr_head_sha — falling back to issue"
        fi
      fi
    fi

    if [[ -n "$head_for_pr" ]]; then
      local pr_payload
      # Use printf|jq pipe to avoid ARG_MAX on large bodies
      pr_payload="$(printf '%s' "$issue_body" | jq -Rs \
        --arg title "[PR #$pr_number] $pr_title" \
        --arg head  "$head_for_pr" \
        --arg base  "$pr_base_ref" \
        '{"title":$title,"body":.,"head":$head,"base":$base}')"

      local pr_create_result pr_err=""
      pr_create_result="$(gh api "repos/$TARGET_ORG/$repo_name/pulls" \
        --method POST \
        --input <(echo "$pr_payload") \
        2>/dev/null)" || {
        pr_err="$(_gh_err_hint "$pr_create_result")"
        if echo "$pr_err" | grep -qi "rate.limit\|secondary rate\|abuse"; then
          warn "  Rate limit hit on PR creation — pausing 60s"
          sleep 60
        fi
        pr_create_result="FAILED"
      }

      if [[ "$pr_create_result" != "FAILED" ]]; then
        tgt_issue_number="$(echo "$pr_create_result" | jq -rs '.[0].number // empty' 2>/dev/null || true)"
        if [[ -n "$tgt_issue_number" && "$tgt_issue_number" != "null" ]]; then
          used_pr_api=1
        else
          warn "  PR #$pr_number: real PR API returned no number — falling back to issue"
          tgt_issue_number=""
        fi
      else
        warn "  PR #$pr_number: real PR creation failed${pr_err:+ — $pr_err} — falling back to issue"
      fi

      # Clean up temp branch even on failure — it has served its purpose or is stale.
      if [[ $created_temp_branch -eq 1 ]]; then
        gh api "repos/$TARGET_ORG/$repo_name/git/refs/heads/$head_for_pr" \
          --method DELETE 2>/dev/null || true
        created_temp_branch=0
      fi
    fi

    # ---- Fall back to issue creation ----------------------------------------
    if [[ $used_pr_api -eq 0 ]]; then
      local issue_payload
      issue_payload="$(printf '%s' "$issue_body" | jq -Rs \
        --arg title "[PR #$pr_number] $pr_title" \
        '{"title":$title,"body":.}')"

      local create_result create_err=""
      create_result="$(gh api "repos/$TARGET_ORG/$repo_name/issues" \
        --method POST \
        --input <(echo "$issue_payload") \
        2>/dev/null)" || {
        create_err="$(_gh_err_hint "$create_result")"
        if echo "$create_err" | grep -qi "rate.limit\|secondary rate\|abuse"; then
          warn "  Rate limit hit on issue creation — pausing 60s"
          sleep 60
        fi
        create_result="FAILED"
      }

      if [[ "$create_result" == "FAILED" ]]; then
        warn "  Failed to create issue for PR #$pr_number${create_err:+ — $create_err} in $TARGET_ORG/$repo_name"
        _upsert_pr "$state_file" "$pr_number" "$pr_url" "" \
          "$pr_title" "failed" "" "$pr_author" "$pr_state"
        failed_count=$((failed_count + 1))
        pause 0.5
        continue
      fi

      tgt_issue_number="$(echo "$create_result" | jq -rs '.[0].number // empty' 2>/dev/null || true)"
    fi

    # Guard: neither path returned a valid number
    if [[ -z "$tgt_issue_number" || "$tgt_issue_number" == "null" ]]; then
      warn "  PR #$pr_number: did not get a valid target number — marking failed"
      _upsert_pr "$state_file" "$pr_number" "$pr_url" "" \
        "$pr_title" "failed" "" "$pr_author" "$pr_state"
      failed_count=$((failed_count + 1))
      pause 0.5
      continue
    fi

    pause 1.5   # rate-limit cooldown after POST /pulls or POST /issues

    # ---- Close the target (historical PR — closed or merged in source) ------
    if [[ $used_pr_api -eq 1 ]]; then
      gh api "repos/$TARGET_ORG/$repo_name/pulls/$tgt_issue_number" \
        --method PATCH \
        -f state="closed" \
        2>/dev/null || warn "  Failed to close PR #$tgt_issue_number in $TARGET_ORG/$repo_name"
      ok "  Mirrored PR #$pr_number -> PR #$tgt_issue_number in $TARGET_ORG/$repo_name"
    else
      gh api "repos/$TARGET_ORG/$repo_name/issues/$tgt_issue_number" \
        --method PATCH \
        -f state="closed" \
        2>/dev/null || warn "  Failed to close issue #$tgt_issue_number in $TARGET_ORG/$repo_name"
      ok "  Mirrored PR #$pr_number -> issue #$tgt_issue_number in $TARGET_ORG/$repo_name"
    fi
    pause 1.0   # rate-limit cooldown after PATCH close

    _upsert_pr "$state_file" "$pr_number" "$pr_url" \
      "$tgt_issue_number" "$pr_title" "mirrored" "$(now)" "$pr_author" "$pr_state"

    _mirror_pr_comments "$repo_name" "$pr_number" "$tgt_issue_number" "$state_file"

    new_count=$((new_count + 1))
    pause 1.0   # rate-limit buffer between PRs

  done < <(echo "$prs" | jq -c '.[]' 2>/dev/null || true)

  state_update_stats "$state_file"
  ok "  Done $repo_name: new=$new_count skipped=$skip_count failed=$failed_count"
}

# ---------------------------------------------------------------------------
# _mirror_pr_comments
# Mirrors three types of PR content onto the target issue/PR:
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
    --paginate 2>/dev/null | \
    jq -rs '[.[] | select(type=="array") | .[] | select(type=="object")]')" || issue_comments='[]'

  local review_comments
  review_comments="$(ghsrc api \
    "repos/$SOURCE_ORG/$repo_name/pulls/$src_pr_number/comments?per_page=100" \
    --paginate 2>/dev/null | \
    jq -rs '[.[] | select(type=="array") | .[] | select(type=="object")]')" || review_comments='[]'

  # Reviews: only those with a non-empty body (e.g. "LGTM" messages)
  local pr_reviews
  pr_reviews="$(ghsrc api \
    "repos/$SOURCE_ORG/$repo_name/pulls/$src_pr_number/reviews?per_page=100" \
    --paginate 2>/dev/null | \
    jq -rs '[.[] | select(type=="array") | .[] | select(type=="object") | select(.body != null and .body != "")]')" \
    || pr_reviews='[]'

  local ic_total rc_total rv_total
  ic_total="$(echo "$issue_comments"  | jq -r 'if type == "array" then length else 0 end' 2>/dev/null || echo 0)"
  rc_total="$(echo "$review_comments" | jq -r 'if type == "array" then length else 0 end' 2>/dev/null || echo 0)"
  rv_total="$(echo "$pr_reviews"      | jq -r 'if type == "array" then length else 0 end' 2>/dev/null || echo 0)"

  local total_comments=$(( ic_total + rc_total + rv_total ))

  if [[ "$total_comments" -eq 0 ]]; then
    _update_pr_comments_status "$state_file" "$src_pr_number" "done" 0
    return 0
  fi

  log "  PR #$src_pr_number: mirroring $ic_total discussion + $rv_total review-bodies + $rc_total inline-review comments..."

  # Pre-fetch existing target comments for idempotency marker checks.
  local tgt_comment_bodies
  tgt_comment_bodies="$(gh api \
    "repos/$TARGET_ORG/$repo_name/issues/$tgt_issue_number/comments?per_page=100" \
    --paginate 2>/dev/null | \
    jq -rs '[.[] | select(type=="array") | .[] | select(type=="object") | .body // ""] | join("\n")')" \
    || tgt_comment_bodies=''

  local mirrored=0

  # -- 1. Discussion comments -----------------------------------------------
  while IFS= read -r c; do
    local c_id c_author c_created c_body c_marker c_full_body c_payload c_result
    c_id="$(echo      "$c" | jq -r '.id')"
    c_author="$(echo  "$c" | jq -r '.user.login // "unknown"')"
    c_created="$(echo "$c" | jq -r '.created_at // ""')"
    c_body="$(echo    "$c" | jq -r '.body // ""')"
    c_marker="<!-- cf-mirror-pr-comment: $SOURCE_ORG/$repo_name#$src_pr_number/$c_id -->"

    if echo "$tgt_comment_bodies" | grep -qF "$c_marker" 2>/dev/null; then
      mirrored=$((mirrored + 1)); continue
    fi

    c_body="$(echo "$c_body" | _encode_at_mentions)"

    c_full_body="**${c_author}** commented on ${c_created}:

---

${c_body}

${c_marker}"

    # Use printf|jq pipe to avoid ARG_MAX on large comment bodies
    c_payload="$(printf '%s' "$c_full_body" | jq -Rs '{"body":.}')"
    c_result="$(gh api "repos/$TARGET_ORG/$repo_name/issues/$tgt_issue_number/comments" \
      --method POST --input <(echo "$c_payload") \
      2>/dev/null)" || c_result="FAILED"
    if [[ "$c_result" == "FAILED" ]]; then
      warn "  Failed to mirror discussion comment $c_id on PR #$src_pr_number"
    else
      mirrored=$((mirrored + 1))
    fi
    pause 1.0   # rate-limit cooldown after POST /issues/{n}/comments
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

    if echo "$tgt_comment_bodies" | grep -qF "$rv_marker" 2>/dev/null; then
      mirrored=$((mirrored + 1)); continue
    fi

    rv_body="$(echo "$rv_body" | _encode_at_mentions)"

    rv_full_body="**${rv_author}** submitted review **${rv_state}** on ${rv_submitted}:

---

${rv_body}

${rv_marker}"

    rv_payload="$(printf '%s' "$rv_full_body" | jq -Rs '{"body":.}')"
    rv_result="$(gh api "repos/$TARGET_ORG/$repo_name/issues/$tgt_issue_number/comments" \
      --method POST --input <(echo "$rv_payload") \
      2>/dev/null)" || rv_result="FAILED"
    if [[ "$rv_result" == "FAILED" ]]; then
      warn "  Failed to mirror review body $rv_id on PR #$src_pr_number"
    else
      mirrored=$((mirrored + 1))
    fi
    pause 1.0   # rate-limit cooldown after POST /issues/{n}/comments
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

    if echo "$tgt_comment_bodies" | grep -qF "$rc_marker" 2>/dev/null; then
      mirrored=$((mirrored + 1)); continue
    fi

    rc_body="$(echo "$rc_body" | _encode_at_mentions)"

    rc_full_body="**${rc_author}** reviewed \`${rc_path}\` line ${rc_line} on ${rc_created}:

---

${rc_body}

${rc_marker}"

    rc_payload="$(printf '%s' "$rc_full_body" | jq -Rs '{"body":.}')"
    rc_result="$(gh api "repos/$TARGET_ORG/$repo_name/issues/$tgt_issue_number/comments" \
      --method POST --input <(echo "$rc_payload") \
      2>/dev/null)" || rc_result="FAILED"
    if [[ "$rc_result" == "FAILED" ]]; then
      warn "  Failed to mirror inline review comment $rc_id on PR #$src_pr_number"
    else
      mirrored=$((mirrored + 1))
    fi
    pause 1.0   # rate-limit cooldown after POST /issues/{n}/comments
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

# ---------------------------------------------------------------------------
# _reconcile_pr — full re-sync of an already-mirrored PR.
# Called in continuous mode for open PRs and PRs that just closed.
# Syncs: title, body (including status line), labels, open/closed state, and
# all three comment types (discussion, review-level, inline review).
# ---------------------------------------------------------------------------
_reconcile_pr() {
  local repo_name="$1"
  local pr_json="$2"
  local pr_number="$3"
  local tgt_issue_number="$4"
  local state_file="$5"

  local pr_state pr_title pr_body pr_author pr_created pr_merged pr_head_ref pr_base_ref
  pr_state="$(echo   "$pr_json" | jq -r '.state')"
  pr_title="$(echo   "$pr_json" | jq -r '.title')"
  pr_body="$(echo    "$pr_json" | jq -r '.body // ""')"
  pr_author="$(echo  "$pr_json" | jq -r '.user.login // "unknown"')"
  pr_created="$(echo "$pr_json" | jq -r '.created_at // ""')"
  pr_merged="$(echo  "$pr_json" | jq -r '.merged_at // ""')"
  pr_head_ref="$(echo "$pr_json" | jq -r '.head.ref // ""')"
  pr_base_ref="$(echo "$pr_json" | jq -r '.base.ref // "main"')"
  local labels
  labels="$(echo "$pr_json" | jq -r '[.labels[].name]')"
  local pr_url="https://github.com/$SOURCE_ORG/$repo_name/pull/$pr_number"
  local marker="<!-- cf-mirror-pr: $SOURCE_ORG/$repo_name#$pr_number -->"

  # ---- Rebuild body with current status line -------------------------------
  local pr_status_str="closed (not merged)"
  if [[ -n "$pr_merged" && "$pr_merged" != "null" ]]; then
    pr_status_str="merged on $pr_merged"
  elif [[ "$pr_state" == "open" ]]; then
    pr_status_str="open"
  fi

  local encoded_body
  encoded_body="$(echo "$pr_body" | _encode_at_mentions)"
  local new_body="> 🔗 **Mirrored PR** [$SOURCE_ORG/$repo_name#$pr_number]($pr_url) | **Author:** $pr_author | **Opened:** $pr_created | **Status:** $pr_status_str
> *GitHub API does not allow setting PR author or timestamps — attribution preserved here.*

---

${encoded_body}

---
${marker}"

  # ---- Fetch current target issue ------------------------------------------
  local tgt_json
  tgt_json="$(gh api "repos/$TARGET_ORG/$repo_name/issues/$tgt_issue_number" \
    2>/dev/null | jq -rs '.[0] // {}')" || tgt_json='{}'
  local tgt_title tgt_body tgt_state tgt_labels_sorted
  tgt_title="$(echo "$tgt_json"  | jq -r '.title // ""'                    2>/dev/null || true)"
  tgt_body="$(echo "$tgt_json"   | jq -r '.body // ""'                     2>/dev/null || true)"
  tgt_state="$(echo "$tgt_json"  | jq -r '.state // "open"'                2>/dev/null || true)"
  tgt_labels_sorted="$(echo "$tgt_json" | jq -c '[.labels[].name] | sort'  2>/dev/null || echo '[]')"
  pause 0.3

  # ---- Compute what needs to change ----------------------------------------
  local patch_payload="{}" body_changed=0
  local new_title="[PR #$pr_number] $pr_title"

  if [[ "$new_title" != "$tgt_title" ]]; then
    patch_payload="$(echo "$patch_payload" | jq --arg v "$new_title" '.title = $v')"
  fi

  local new_body_norm tgt_body_norm
  new_body_norm="$(echo "$new_body" | sed "s|https://github\.com/${SOURCE_ORG}/|https://github.com/${TARGET_ORG}/|g")"
  tgt_body_norm="$(echo "$tgt_body" | sed "s|https://github\.com/${SOURCE_ORG}/|https://github.com/${TARGET_ORG}/|g")"
  if [[ "$new_body_norm" != "$tgt_body_norm" ]]; then
    patch_payload="$(printf '%s' "$new_body" | \
      jq -Rs --argjson base "$patch_payload" '$base + {"body":.}')"
    body_changed=1
  fi

  local src_labels_sorted
  src_labels_sorted="$(echo "$labels" | jq -c 'sort' 2>/dev/null || echo '[]')"
  if [[ "$src_labels_sorted" != "$tgt_labels_sorted" ]]; then
    patch_payload="$(echo "$patch_payload" | jq --argjson v "$labels" '.labels = $v')"
  fi

  if [[ "$pr_state" == "closed" && "$tgt_state" != "closed" ]]; then
    patch_payload="$(echo "$patch_payload" | jq '.state = "closed"')"
  fi

  if [[ "$patch_payload" != "{}" ]]; then
    gh api "repos/$TARGET_ORG/$repo_name/issues/$tgt_issue_number" \
      --method PATCH \
      --input <(echo "$patch_payload") \
      2>/dev/null || warn "  Failed to reconcile PR $repo_name#$pr_number → #$tgt_issue_number"
    log "  Reconciled PR #$pr_number → #$tgt_issue_number ($(echo "$patch_payload" | jq -r 'keys | join(", ")'))"
    pause 1.0
    [[ "$body_changed" -eq 1 ]] && _clear_crossref_record "$repo_name" "$tgt_issue_number"
  fi

  # ---- Reconcile all comment types -----------------------------------------
  _reconcile_pr_comments "$repo_name" "$pr_number" "$tgt_issue_number" "$state_file"

  # ---- Update state file ---------------------------------------------------
  _upsert_pr "$state_file" "$pr_number" "$pr_url" \
    "$tgt_issue_number" "$pr_title" "mirrored" "$(now)" "$pr_author" "$pr_state"
}

# ---------------------------------------------------------------------------
# _reconcile_pr_comments — add new and update edited comments for all three
# PR comment types (discussion, review-level bodies, inline review comments).
# Uses the same normalise-before-compare strategy as _reconcile_issue_comments.
# ---------------------------------------------------------------------------
_reconcile_pr_comments() {
  local repo_name="$1"
  local src_pr_number="$2"
  local tgt_issue_number="$3"
  local state_file="$4"

  # Fetch all three source comment types
  local issue_comments review_comments pr_reviews
  issue_comments="$(ghsrc api \
    "repos/$SOURCE_ORG/$repo_name/issues/$src_pr_number/comments?per_page=100" \
    --paginate 2>/dev/null | \
    jq -rs '[.[] | select(type=="array") | .[] | select(type=="object")]')" || issue_comments='[]'

  review_comments="$(ghsrc api \
    "repos/$SOURCE_ORG/$repo_name/pulls/$src_pr_number/comments?per_page=100" \
    --paginate 2>/dev/null | \
    jq -rs '[.[] | select(type=="array") | .[] | select(type=="object")]')" || review_comments='[]'

  pr_reviews="$(ghsrc api \
    "repos/$SOURCE_ORG/$repo_name/pulls/$src_pr_number/reviews?per_page=100" \
    --paginate 2>/dev/null | \
    jq -rs '[.[] | select(type=="array") | .[] | select(type=="object") | select(.body != null and .body != "")]')" \
    || pr_reviews='[]'

  # Pre-fetch all target comments once — id + body needed for update path
  local tgt_comments
  tgt_comments="$(gh api \
    "repos/$TARGET_ORG/$repo_name/issues/$tgt_issue_number/comments?per_page=100" \
    --paginate 2>/dev/null | \
    jq -rs '[.[] | select(type=="array") | .[] | select(type=="object") | {id, body}]')" || tgt_comments='[]'

  local mirrored=0

  # Shared helper: given marker + full_body, update if changed or create if absent.
  # Sets $mirrored in the caller's scope (uses nameref-style side effect via echo).
  _sync_comment() {
    local c_marker="$1" c_full_body="$2"
    local tgt_c_id
    tgt_c_id="$(echo "$tgt_comments" | jq -r \
      --arg m "$c_marker" \
      '.[] | select(.body | contains($m)) | .id' 2>/dev/null | head -1 || true)"

    if [[ -n "$tgt_c_id" && "$tgt_c_id" != "null" ]]; then
      local tgt_c_body new_norm tgt_norm
      tgt_c_body="$(echo "$tgt_comments" | jq -r \
        --argjson id "$tgt_c_id" '.[] | select(.id == $id) | .body // ""' \
        2>/dev/null || true)"
      new_norm="$(echo "$c_full_body" | sed "s|https://github\.com/${SOURCE_ORG}/|https://github.com/${TARGET_ORG}/|g")"
      tgt_norm="$(echo "$tgt_c_body"  | sed "s|https://github\.com/${SOURCE_ORG}/|https://github.com/${TARGET_ORG}/|g")"
      if [[ "$new_norm" != "$tgt_norm" ]]; then
        gh api "repos/$TARGET_ORG/$repo_name/issues/comments/$tgt_c_id" \
          --method PATCH \
          --input <(printf '%s' "$c_full_body" | jq -Rs '{"body":.}') \
          2>/dev/null || warn "  Failed to update comment on PR #$src_pr_number"
        pause 1.0
      fi
      mirrored=$((mirrored + 1))
    else
      local c_result
      c_result="$(gh api \
        "repos/$TARGET_ORG/$repo_name/issues/$tgt_issue_number/comments" \
        --method POST \
        --input <(printf '%s' "$c_full_body" | jq -Rs '{"body":.}') \
        2>/dev/null)" || c_result="FAILED"
      [[ "$c_result" != "FAILED" ]] && mirrored=$((mirrored + 1)) || \
        warn "  Failed to create comment on PR #$src_pr_number"
      pause 1.0
    fi
  }

  # -- 1. Discussion comments ------------------------------------------------
  while IFS= read -r c; do
    local c_id c_author c_created c_body c_marker c_full_body
    c_id="$(echo      "$c" | jq -r '.id')"
    c_author="$(echo  "$c" | jq -r '.user.login // "unknown"')"
    c_created="$(echo "$c" | jq -r '.created_at // ""')"
    c_body="$(echo    "$c" | jq -r '.body // ""' | _encode_at_mentions)"
    c_marker="<!-- cf-mirror-pr-comment: $SOURCE_ORG/$repo_name#$src_pr_number/$c_id -->"
    c_full_body="**${c_author}** commented on ${c_created}:

---

${c_body}

${c_marker}"
    _sync_comment "$c_marker" "$c_full_body"
  done < <(echo "$issue_comments" | jq -c '.[]' 2>/dev/null || true)

  # -- 2. Review-level bodies (APPROVED / CHANGES_REQUESTED + message) -------
  while IFS= read -r rv; do
    local rv_id rv_author rv_state rv_submitted rv_body rv_marker rv_full_body
    rv_id="$(echo        "$rv" | jq -r '.id')"
    rv_author="$(echo    "$rv" | jq -r '.user.login // "unknown"')"
    rv_state="$(echo     "$rv" | jq -r '.state // "COMMENTED"')"
    rv_submitted="$(echo "$rv" | jq -r '.submitted_at // ""')"
    rv_body="$(echo      "$rv" | jq -r '.body // ""' | _encode_at_mentions)"
    rv_marker="<!-- cf-mirror-pr-review: $SOURCE_ORG/$repo_name#$src_pr_number/$rv_id -->"
    rv_full_body="**${rv_author}** submitted review **${rv_state}** on ${rv_submitted}:

---

${rv_body}

${rv_marker}"
    _sync_comment "$rv_marker" "$rv_full_body"
  done < <(echo "$pr_reviews" | jq -c '.[]' 2>/dev/null || true)

  # -- 3. Inline review comments (with file + line context) ------------------
  while IFS= read -r rc; do
    local rc_id rc_author rc_created rc_body rc_path rc_line rc_marker rc_full_body
    rc_id="$(echo      "$rc" | jq -r '.id')"
    rc_author="$(echo  "$rc" | jq -r '.user.login // "unknown"')"
    rc_created="$(echo "$rc" | jq -r '.created_at // ""')"
    rc_body="$(echo    "$rc" | jq -r '.body // ""' | _encode_at_mentions)"
    rc_path="$(echo    "$rc" | jq -r '.path // "(unknown file)"')"
    rc_line="$(echo    "$rc" | jq -r '(.line // .original_line) | tostring' 2>/dev/null || echo '?')"
    rc_marker="<!-- cf-mirror-pr-review-inline: $SOURCE_ORG/$repo_name#$src_pr_number/$rc_id -->"
    rc_full_body="**${rc_author}** reviewed \`${rc_path}\` line ${rc_line} on ${rc_created}:

---

${rc_body}

${rc_marker}"
    _sync_comment "$rc_marker" "$rc_full_body"
  done < <(echo "$review_comments" | jq -c '.[]' 2>/dev/null || true)

  _update_pr_comments_status "$state_file" "$src_pr_number" "done" "$mirrored"
  ok "  Reconciled $mirrored comments for PR #$src_pr_number"
}

main "$@"
