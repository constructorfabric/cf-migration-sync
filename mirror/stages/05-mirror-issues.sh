#!/usr/bin/env bash
# mirror/stages/05-mirror-issues.sh
# Mirror issues from source repos to target repos.
# - Creates issues WITHOUT assignees (to avoid notifications)
# - Stores assignees in state for stage 08
# - Adds cf-mirror marker in body for idempotency
# State file: state/issues/<repo-name>.yaml
#
# Usage:
#   SOURCE_ORG=cyberfabric TARGET_ORG=constructorfabric \
#   GH_TOKEN=xxx GH_TOKEN_SOURCE=xxx \
#   ./mirror/stages/05-mirror-issues.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

TARGET_ORG="${TARGET_ORG:-constructorfabric}"
STATE_DIR="$REPO_ROOT/state/issues"

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
main() {
  check_dry_run "$@"
  preflight

  log "Stage 05 — mirror-issues starting"
  mkdir -p "$STATE_DIR"

  # Fetch all source repos
  log "Fetching source repos from $SOURCE_ORG..."
  local repos
  repos="$(gh_paginate ghsrc "orgs/$SOURCE_ORG/repos")"
  local total_repos
  total_repos="$(echo "$repos" | jq 'length')"
  log "Found $total_repos repos in $SOURCE_ORG"

  # ---- Load excluded repos from config ------------------------------------
  local excluded_repos
  excluded_repos="$(jq -r '.stage_05_mirror_issues.exclude_repos[] // empty' \
    "$MIRROR_CONFIG" 2>/dev/null || true)"
  if [[ -n "$excluded_repos" ]]; then
    log "Excluded repos: $(echo "$excluded_repos" | tr '\n' ' ')"
  fi

  local repo_idx=0

  while IFS= read -r repo; do
    local repo_name
    repo_name="$(echo "$repo" | jq -r '.name')"
    local has_issues
    has_issues="$(echo "$repo" | jq -r '.has_issues // true')"

    repo_idx=$((repo_idx + 1))

    # Check exclusion list from config
    if [[ -n "$excluded_repos" ]] && echo "$excluded_repos" | grep -qx "$repo_name" 2>/dev/null; then
      log "[$repo_idx/$total_repos] Skipping excluded repo: $repo_name"
      continue
    fi

    log "[$repo_idx/$total_repos] Processing issues for $repo_name (has_issues=$has_issues)..."

    if [[ "$has_issues" != "true" ]]; then
      log "  Skipping $repo_name — issues disabled"
      continue
    fi

    _mirror_repo_issues "$repo_name"
    pause 0.5

  done < <(echo "$repos" | jq -c '.[]')

  log "Stage 05 complete"

  if [[ "$DRY_RUN" -eq 0 ]]; then
    commit_state "mirror: state after stage 05 (mirror-issues) [skip ci]"
  fi
}

# ---------------------------------------------------------------------------
_mirror_repo_issues() {
  local repo_name="$1"
  local state_file="$STATE_DIR/$repo_name.yaml"

  state_init "$state_file" "05-mirror-issues"

  # Fetch all source issues (open + closed), exclude pull requests.
  # BUG-02 fix: use --paginate so repos with >100 issues in either state are fully fetched.
  log "  Fetching issues from $SOURCE_ORG/$repo_name..."
  local issues_open issues_closed all_issues

  issues_open="$(ghsrc api \
    "repos/$SOURCE_ORG/$repo_name/issues?state=open&per_page=100" \
    --paginate 2>/dev/null | jq -s 'add // []' || echo '[]')"
  issues_closed="$(ghsrc api \
    "repos/$SOURCE_ORG/$repo_name/issues?state=closed&per_page=100" \
    --paginate 2>/dev/null | jq -s 'add // []' || echo '[]')"

  # Filter out pull requests; unique_by(.id) deduplicates issues that changed
  # state between the two API calls (BUG-16 fix).
  all_issues="$(echo "$issues_open $issues_closed" | \
    jq -s 'add // [] | map(select(.pull_request == null)) | unique_by(.id)')"

  local total_issues
  total_issues="$(echo "$all_issues" | jq 'length')"
  log "  Found $total_issues issues in $repo_name"

  if [[ "$total_issues" -eq 0 ]]; then
    return 0
  fi

  # Check what's already in the target (for idempotency via marker)
  # Use --paginate to handle repos with >100 already-mirrored issues.
  log "  Checking existing mirrored issues in $TARGET_ORG/$repo_name..."
  local tgt_issues
  tgt_issues="$(gh api \
    "repos/$TARGET_ORG/$repo_name/issues?state=all&per_page=100" \
    --paginate 2>/dev/null | jq -s 'add // []' || echo '[]')"

  local processed=0
  local new_count=0
  local skip_count=0
  local failed_count=0

  while IFS= read -r issue; do
    local src_number
    src_number="$(echo "$issue" | jq -r '.number')"
    local src_id
    src_id="$(echo "$issue" | jq -r '.id')"
    local src_state
    src_state="$(echo "$issue" | jq -r '.state')"
    local title
    title="$(echo "$issue" | jq -r '.title')"
    local body
    body="$(echo "$issue" | jq -r '.body // ""')"
    local assignees
    assignees="$(echo "$issue" | jq -r '[.assignees[].login]')"
    local labels
    labels="$(echo "$issue" | jq -r '[.labels[].name]')"
    local milestone_title
    milestone_title="$(echo "$issue" | jq -r '.milestone.title // ""')"
    local src_author src_created
    src_author="$(echo "$issue" | jq -r '.user.login // "unknown"')"
    src_created="$(echo "$issue" | jq -r '.created_at // ""')"

    processed=$((processed + 1))
    if (( processed % 25 == 0 )); then
      log "  Progress: $processed/$total_issues issues..."
    fi

    # ---- Check idempotency via state file --------------------------------
    local already_status
    already_status="$(jq -r --argjson n "$src_number" \
      '.items[] | select(.source_number == $n) | .status // empty' \
      "$state_file" 2>/dev/null | head -1 || true)"

    if [[ "$already_status" == "mirrored" ]]; then
      local already_comments_status tgt_number_in_state
      already_comments_status="$(jq -r --argjson n "$src_number" \
        '.items[] | select(.source_number == $n) | .comments_status // empty' \
        "$state_file" 2>/dev/null | head -1 || true)"
      if [[ "$already_comments_status" == "done" ]]; then
        # Issue body + comments both done — fully skip
        skip_count=$((skip_count + 1))
        continue
      fi
      # Body mirrored but comments not yet done — complete the comment sync
      tgt_number_in_state="$(jq -r --argjson n "$src_number" \
        '.items[] | select(.source_number == $n) | .target_number // empty' \
        "$state_file" 2>/dev/null | head -1 || true)"
      if [[ -n "$tgt_number_in_state" && "$tgt_number_in_state" != "null" ]]; then
        log "  Issue #$src_number body already mirrored — completing comment sync..."
        _mirror_issue_comments \
          "$repo_name" "$src_number" "$tgt_number_in_state" "$state_file"
      fi
      skip_count=$((skip_count + 1))
      continue
    fi

    # ---- Check idempotency via body marker in target --------------------
    local marker="<!-- cf-mirror: $SOURCE_ORG/$repo_name#$src_number -->"
    local existing_target_number
    existing_target_number="$(echo "$tgt_issues" | jq -r \
      --arg marker "$marker" \
      '.[] | select(.body != null and (.body | contains($marker))) | .number' \
      2>/dev/null | head -1 || true)"

    if [[ -n "$existing_target_number" ]]; then
      log "  Issue #$src_number already mirrored as #$existing_target_number, syncing state+comments"
      _upsert_issue "$state_file" "$src_number" "$src_id" "$src_state" \
        "$title" "$existing_target_number" "" "$assignees" "mirrored" "$(now)" "pending"
      # Sync closed/open state in target if needed
      if [[ "$src_state" == "closed" ]]; then
        gh api "repos/$TARGET_ORG/$repo_name/issues/$existing_target_number" \
          --method PATCH \
          -f state="closed" \
          2>/dev/null || warn "  Failed to close issue #$existing_target_number in $TARGET_ORG/$repo_name"
        pause 0.3
      fi
      _mirror_issue_comments \
        "$repo_name" "$src_number" "$existing_target_number" "$state_file"
      skip_count=$((skip_count + 1))
      continue
    fi

    if dry_run_skip "create issue '$title' in $TARGET_ORG/$repo_name"; then
      new_count=$((new_count + 1))
      continue
    fi

    # ---- Build body with visible attribution + idempotency marker ------
    local src_url="https://github.com/$SOURCE_ORG/$repo_name/issues/$src_number"
    local attribution="> 🔗 **Mirrored from** [$SOURCE_ORG/$repo_name#$src_number]($src_url)
> Originally opened by **${src_author}** on ${src_created}"

    # Encode @mentions in source body to prevent GitHub notification emails
    local encoded_body
    encoded_body="$(echo "$body" | _encode_at_mentions)"

    local full_body
    if [[ -n "$body" ]]; then
      full_body="${attribution}

---

${encoded_body}

---
${marker}"
    else
      full_body="${attribution}

---
${marker}"
    fi

    # ---- Lookup target milestone number --------------------------------
    local milestone_number=""
    if [[ -n "$milestone_title" ]]; then
      milestone_number="$(gh api \
        "repos/$TARGET_ORG/$repo_name/milestones?per_page=100" \
        2>/dev/null | \
        jq -r --arg t "$milestone_title" '.[] | select(.title == $t) | .number' \
        | head -1 || true)"
    fi

    # ---- Create issue in target ----------------------------------------
    local payload
    payload="$(jq -n \
      --arg title "$title" \
      --arg body  "$full_body" \
      --argjson labels "$labels" \
      '{"title":$title,"body":$body,"labels":$labels}')"

    if [[ -n "$milestone_number" && "$milestone_number" != "null" ]]; then
      payload="$(echo "$payload" | jq --argjson ms "$milestone_number" '.milestone = $ms')"
    fi

    # First attempt: with labels and milestone
    local create_result
    create_result="$(gh api "repos/$TARGET_ORG/$repo_name/issues" \
      --method POST \
      --input <(echo "$payload") \
      2>/dev/null || echo 'FAILED')"

    # Retry without labels if Validation Failed
    if [[ "$create_result" == "FAILED" ]] || \
       echo "$create_result" | jq -e '.message // "" | test("Validation Failed")' &>/dev/null; then
      warn "  Issue #$src_number: retry without labels..."
      payload="$(echo "$payload" | jq 'del(.labels)')"
      create_result="$(gh api "repos/$TARGET_ORG/$repo_name/issues" \
        --method POST \
        --input <(echo "$payload") \
        2>/dev/null || echo 'FAILED')"
    fi

    # Retry without milestone too
    if [[ "$create_result" == "FAILED" ]] || \
       echo "$create_result" | jq -e '.message // "" | test("Validation Failed")' &>/dev/null; then
      warn "  Issue #$src_number: retry without milestone..."
      payload="$(echo "$payload" | jq 'del(.milestone)')"
      create_result="$(gh api "repos/$TARGET_ORG/$repo_name/issues" \
        --method POST \
        --input <(echo "$payload") \
        2>/dev/null || echo 'FAILED')"
    fi

    if [[ "$create_result" == "FAILED" ]]; then
      warn "  Failed to create issue #$src_number ('$title') in $TARGET_ORG/$repo_name"
      _upsert_issue "$state_file" "$src_number" "$src_id" "$src_state" \
        "$title" "" "" "$assignees" "failed" "" "none"
      failed_count=$((failed_count + 1))
      pause 0.3
      continue
    fi

    local tgt_number
    tgt_number="$(echo "$create_result" | jq -rs '.[0].number // empty' 2>/dev/null || true)"
    local tgt_node_id
    tgt_node_id="$(echo "$create_result" | jq -rs '.[0].node_id // empty' 2>/dev/null || true)"

    # ---- Close issue in target if source is closed ----------------------
    if [[ "$src_state" == "closed" ]]; then
      gh api "repos/$TARGET_ORG/$repo_name/issues/$tgt_number" \
        --method PATCH \
        -f state="closed" \
        2>/dev/null || warn "  Failed to close issue #$tgt_number in $TARGET_ORG/$repo_name"
      pause 0.3
    fi

    ok "  Created issue #$src_number -> #$tgt_number in $TARGET_ORG/$repo_name"

    # Determine assignees_status
    local assignees_count
    assignees_count="$(echo "$assignees" | jq 'length')"
    local assignees_status="none"
    if [[ "$assignees_count" -gt 0 ]]; then
      assignees_status="pending"
    fi

    _upsert_issue "$state_file" "$src_number" "$src_id" "$src_state" \
      "$title" "$tgt_number" "$tgt_node_id" "$assignees" "mirrored" "$(now)" "$assignees_status"

    # ---- Mirror issue comments -------------------------------------------
    _mirror_issue_comments "$repo_name" "$src_number" "$tgt_number" "$state_file"

    new_count=$((new_count + 1))
    pause 0.3

  done < <(echo "$all_issues" | jq -c '.[]')

  state_update_stats "$state_file"
  ok "  Done $repo_name: new=$new_count skipped=$skip_count failed=$failed_count"
}

# ---------------------------------------------------------------------------
# _upsert_issue — upsert an issue record in a state file
_upsert_issue() {
  local state_file="$1"
  local src_number="$2"
  local src_id="$3"
  local src_state="$4"
  local title="$5"
  local tgt_number="$6"
  local tgt_node_id="$7"
  local assignees="$8"
  local status="$9"
  local mirrored_at="${10:-}"
  local assignees_status="${11:-none}"

  local record
  record="$(jq -n \
    --argjson src_num  "$src_number" \
    --argjson src_id   "$src_id" \
    --arg     src_st   "$src_state" \
    --argjson tgt_num  "${tgt_number:-null}" \
    --arg     tgt_nid  "${tgt_node_id:-}" \
    --arg     title    "$title" \
    --argjson assignees "$assignees" \
    --arg     status   "$status" \
    --arg     mat      "${mirrored_at:-}" \
    --arg     ast      "$assignees_status" \
    '{
      source_number:        $src_num,
      source_id:            $src_id,
      source_state:         $src_st,
      target_number:        $tgt_num,
      target_node_id:       (if $tgt_nid == "" then null else $tgt_nid end),
      title:                $title,
      assignees:            $assignees,
      status:               $status,
      mirrored_at:          (if $mat == "" then null else $mat end),
      assignees_status:     $ast,
      assignees_applied_at: null,
      comments_status:      "none",
      comments_mirrored:    0
    }')"

  local tmp
  tmp="$(mktemp)"
  # Preserve comments_status / comments_mirrored from existing record so that
  # a re-run of issue creation does not reset the comment-sync progress.
  jq --argjson sn "$src_number" --argjson rec "$record" \
    'if (.items | map(select(.source_number == $sn)) | length) > 0
     then .items = [.items[] | if .source_number == $sn then
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
# _mirror_issue_comments — fetch source comments and create in target
# with attribution headers. Idempotent via state (comments_status=done).
_mirror_issue_comments() {
  local repo_name="$1"
  local src_number="$2"
  local tgt_number="$3"
  local state_file="$4"

  local comments
  comments="$(ghsrc api \
    "repos/$SOURCE_ORG/$repo_name/issues/$src_number/comments?per_page=100" \
    --paginate 2>/dev/null | jq -s 'add // []' || echo '[]')"

  local total_comments
  total_comments="$(echo "$comments" | jq 'length' 2>/dev/null || echo 0)"

  if [[ "$total_comments" -eq 0 ]]; then
    _update_comments_status "$state_file" "$src_number" "done" 0
    return 0
  fi

  log "  Mirroring $total_comments comments for issue #$src_number -> #$tgt_number..."

  # BUG-03 fix: pre-fetch existing target comments so we can check markers before
  # posting.  Without this, an interrupted run re-posts all comments (duplicates).
  local tgt_comment_bodies
  tgt_comment_bodies="$(gh api \
    "repos/$TARGET_ORG/$repo_name/issues/$tgt_number/comments?per_page=100" \
    --paginate 2>/dev/null | jq -s 'add // [] | map(.body // "") | join("\n")' || echo '')"

  local mirrored=0
  while IFS= read -r comment; do
    local c_id c_author c_created c_body
    c_id="$(echo      "$comment" | jq -r '.id')"
    c_author="$(echo  "$comment" | jq -r '.user.login // "unknown"')"
    c_created="$(echo "$comment" | jq -r '.created_at // ""')"
    c_body="$(echo    "$comment" | jq -r '.body // ""')"

    # Marker for idempotency on future re-runs (stored in comment body)
    local c_marker="<!-- cf-mirror-comment: $SOURCE_ORG/$repo_name#$src_number/$c_id -->"

    # Skip if already posted in a previous (possibly interrupted) run
    if echo "$tgt_comment_bodies" | grep -qF "$c_marker" 2>/dev/null; then
      mirrored=$((mirrored + 1))
      continue
    fi

    # Encode @mentions in comment body to prevent GitHub notification emails
    c_body="$(echo "$c_body" | _encode_at_mentions)"

    local c_full_body
    c_full_body="**${c_author}** commented on ${c_created}:

---

${c_body}

${c_marker}"

    local c_payload
    c_payload="$(jq -n --arg body "$c_full_body" '{"body":$body}')"

    local c_result
    c_result="$(gh api "repos/$TARGET_ORG/$repo_name/issues/$tgt_number/comments" \
      --method POST \
      --input <(echo "$c_payload") \
      2>/dev/null || echo 'FAILED')"

    if [[ "$c_result" == "FAILED" ]]; then
      warn "  Failed to mirror comment $c_id on issue #$src_number"
    else
      mirrored=$((mirrored + 1))
    fi
    pause 0.2
  done < <(echo "$comments" | jq -c '.[]')

  _update_comments_status "$state_file" "$src_number" "done" "$mirrored"
  ok "  Mirrored $mirrored/$total_comments comments for issue #$src_number"
}

# ---------------------------------------------------------------------------
_update_comments_status() {
  local state_file="$1"
  local src_number="$2"
  local status="$3"
  local count="$4"

  local tmp
  tmp="$(mktemp)"
  jq --argjson sn "$src_number" --arg st "$status" --argjson count "$count" \
    '.items = [.items[] |
      if .source_number == $sn
      then .comments_status = $st | .comments_mirrored = $count
      else .
      end]' \
    "$state_file" > "$tmp"
  mv "$tmp" "$state_file"
}

main "$@"
