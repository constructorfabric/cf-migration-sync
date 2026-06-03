#!/usr/bin/env bash
# mirror/stages/05-mirror-issues.sh
# Mirror issues from source repos to target repos.
# - Creates issues WITHOUT assignees (to avoid notifications)
# - Stores assignees in state for stage 08
# - Adds cf-mirror marker in body for idempotency
# State file: state/issues/<repo-name>.yaml
#
# Modes (MIRROR_MODE):
#   full   — fetch source issues and create them in target in one pass (default).
#   export — fetch raw source issues + comments and serialize them into the state
#            file (source_data / source_comments). NEVER contacts the target org.
#   import — read serialized issues from state files and create them in the target,
#            building attribution + markers at import time. NEVER contacts source.
#            Resumable: items with target_number already set are skipped; comment
#            posting resumes from comments_mirrored without re-reading the target.
#
# Usage:
#   SOURCE_ORG=cyberfabric TARGET_ORG=constructorfabric \
#   GH_TOKEN=xxx GH_TOKEN_SOURCE=xxx \
#   MIRROR_MODE=full|export|import \
#   ./mirror/stages/05-mirror-issues.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

TARGET_ORG="${TARGET_ORG:-}"   # required; validated in preflight (no hardcoded default)
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
            # L1 FIX: also match an optional "/team-name" suffix so TEAM mentions
            # (@org/team) are encoded too — previously the "/" ended the match,
            # leaving @org intact and STILL firing team notifications, defeating
            # the whole purpose of this function. The captured group keeps the
            # "user" or "org/team" text; only the leading @ is replaced.
            out.append(re.sub(r"@([a-zA-Z0-9][-a-zA-Z0-9]*(?:/[a-zA-Z0-9][-a-zA-Z0-9_]*)?)", r"&#64;\1", p))
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

  log "Stage 05 — mirror-issues starting (mode=$MIRROR_MODE)"
  mkdir -p "$STATE_DIR"

  # ---- Import mode: replay serialized state into the target, no source access -
  if in_import; then
    _import_all_issues
    log "Stage 05 complete (import)"
    [[ "$DRY_RUN" -eq 0 ]] && \
      commit_state "mirror: import stage 05 (mirror-issues) [skip ci]"
    return 0
  fi

  # ---- full / export: enumerate source repos --------------------------------
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

    if in_export; then
      _export_repo_issues "$repo_name"
    else
      _mirror_repo_issues "$repo_name"
    fi
    pause 2.0

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
  local _body_tmp
  _body_tmp="$(mktemp)"
  trap 'rm -f "$_body_tmp"' RETURN

  state_init "$state_file" "05-mirror-issues"

  # Fetch all source issues (open + closed), exclude pull requests.
  # BUG-02 fix: use --paginate so repos with >100 issues in either state are fully fetched.
  log "  Fetching issues from $SOURCE_ORG/$repo_name..."
  local issues_open issues_closed all_issues

  # RC-8 fix (paginated REST arrays): gh api --paginate emits one JSON array per
  # page. jq -rs slurps them into [[page1_items...],[page2_items...]]. The outer
  # .[] yields arrays (not objects), so select(type=="object") must be preceded by
  # select(type=="array") | .[] to unwrap each page first.
  issues_open="$(ghsrc api \
    "repos/$SOURCE_ORG/$repo_name/issues?state=open&per_page=100" \
    --paginate 2>/dev/null | \
    jq -rs '[.[] | select(type=="array") | .[] | select(type=="object")]')" || issues_open='[]'
  issues_closed="$(ghsrc api \
    "repos/$SOURCE_ORG/$repo_name/issues?state=closed&per_page=100" \
    --paginate 2>/dev/null | \
    jq -rs '[.[] | select(type=="array") | .[] | select(type=="object")]')" || issues_closed='[]'

  # Filter out pull requests; unique_by(.id) deduplicates issues that changed
  # state between the two API calls (BUG-16 fix).
  # printf keeps the two already-flat arrays as separate top-level JSON values
  # so the same page-unwrapping pattern works correctly.
  all_issues="$(printf '%s\n' "$issues_open" "$issues_closed" | \
    jq -rs '[.[] | select(type=="array") | .[] | select(type=="object") | select(.pull_request == null)] | unique_by(.id)')"

  local total_issues
  total_issues="$(echo "$all_issues" | jq -r 'if type=="array" then length else 0 end' 2>/dev/null || echo 0)"
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
    --paginate 2>/dev/null | \
    jq -rs '[.[] | select(type=="array") | .[] | select(type=="object")]')" || tgt_issues='[]'

  local processed=0
  local new_count=0
  local skip_count=0
  local failed_count=0
  local wrote_count=0   # counts actual state writes; drives checkpoint commits

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
    local issue_type_name
    issue_type_name="$(echo "$issue" | jq -r '.type.name // ""')"

    processed=$((processed + 1))
    if (( processed % 25 == 0 )); then
      log "  Progress: $processed/$total_issues issues (wrote=$wrote_count new=$new_count skipped=$skip_count)..."
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
      tgt_number_in_state="$(jq -r --argjson n "$src_number" \
        '.items[] | select(.source_number == $n) | .target_number // empty' \
        "$state_file" 2>/dev/null | head -1 || true)"

      if [[ "${CONTINUOUS:-false}" == "true" && -n "$tgt_number_in_state" && "$tgt_number_in_state" != "null" ]]; then
        # Full reconcile for open issues (actively changing) and issues that just
        # transitioned open→closed (title/body may have been edited before close).
        # Already-closed issues get lightweight treatment: new comments only.
        local state_file_src_state
        state_file_src_state="$(jq -r --argjson n "$src_number" \
          '.items[] | select(.source_number == $n) | .source_state // empty' \
          "$state_file" 2>/dev/null | head -1 || true)"

        if [[ "$src_state" == "open" || \
              ( "$src_state" == "closed" && "$state_file_src_state" == "open" ) ]]; then
          _reconcile_issue "$repo_name" "$issue" "$src_number" "$tgt_number_in_state" "$state_file"
        else
          _mirror_issue_comments "$repo_name" "$src_number" "$tgt_number_in_state" "$state_file"
        fi
        skip_count=$((skip_count + 1))
        continue
      fi

      if [[ "$already_comments_status" == "done" ]]; then
        # Normal mode: body + comments both done — fully skip
        skip_count=$((skip_count + 1))
        continue
      fi
      # Body mirrored but comments not yet done — complete the comment sync
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
      local _m_asgn_status="none"
      [[ "$(echo "$assignees" | jq 'length')" -gt 0 ]] && _m_asgn_status="pending"
      _upsert_issue "$state_file" "$src_number" "$src_id" "$src_state" \
        "$title" "$existing_target_number" "" "$assignees" "mirrored" "$(now)" "$_m_asgn_status"
      # Sync closed/open state in target if needed
      if [[ "$src_state" == "closed" ]]; then
        gh api "repos/$TARGET_ORG/$repo_name/issues/$existing_target_number" \
          --method PATCH \
          -f state="closed" \
          2>/dev/null || warn "  Failed to close issue #$existing_target_number in $TARGET_ORG/$repo_name"
        pause 3.0   # rate-limit cooldown after PATCH /issues
      fi
      _mirror_issue_comments \
        "$repo_name" "$src_number" "$existing_target_number" "$state_file"
      wrote_count=$((wrote_count + 1))
      if (( wrote_count % 10 == 0 )) && [[ "$DRY_RUN" -eq 0 ]]; then
        commit_state "mirror: checkpoint $wrote_count issue writes in $repo_name [skip ci]"
      fi
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
    # Use printf|jq pipe to avoid ARG_MAX on large issue bodies
    local payload
    payload="$(printf '%s' "$full_body" | jq -Rs \
      --arg title "$title" \
      --argjson labels "$labels" \
      '{"title":$title,"body":.,"labels":$labels}')"

    if [[ -n "$milestone_number" && "$milestone_number" != "null" ]]; then
      payload="$(echo "$payload" | jq --argjson ms "$milestone_number" '.milestone = $ms')"
    fi
    # Include issue type (Bug/Feature/Task) — GitHub REST API supports this since 2024.
    if [[ -n "$issue_type_name" ]]; then
      payload="$(echo "$payload" | jq --arg t "$issue_type_name" '.type = $t')"
    fi

    # First attempt: with labels, milestone, and type
    local create_result
    printf '%s' "$payload" > "$_body_tmp"
    create_result="$(gh api "repos/$TARGET_ORG/$repo_name/issues" \
      --method POST \
      --input "$_body_tmp" \
      2>/dev/null)" || create_result="FAILED"

    # Retry without labels only for Validation Failed (not for network/auth errors —
    # those go straight to the FAILED check below to avoid burning rate-limit quota).
    if echo "$create_result" | jq -e '.message // "" | test("Validation Failed")' &>/dev/null; then
      warn "  Issue #$src_number: retry without labels..."
      payload="$(echo "$payload" | jq 'del(.labels)')"
      printf '%s' "$payload" > "$_body_tmp"
      create_result="$(gh api "repos/$TARGET_ORG/$repo_name/issues" \
        --method POST \
        --input "$_body_tmp" \
        2>/dev/null)" || create_result="FAILED"
    fi

    # Retry without milestone too
    if echo "$create_result" | jq -e '.message // "" | test("Validation Failed")' &>/dev/null; then
      warn "  Issue #$src_number: retry without milestone..."
      payload="$(echo "$payload" | jq 'del(.milestone)')"
      printf '%s' "$payload" > "$_body_tmp"
      create_result="$(gh api "repos/$TARGET_ORG/$repo_name/issues" \
        --method POST \
        --input "$_body_tmp" \
        2>/dev/null)" || create_result="FAILED"
    fi
    # Retry without type (type name may not exist in target org yet)
    if echo "$create_result" | jq -e '.message // "" | test("Validation Failed")' &>/dev/null; then
      warn "  Issue #$src_number: retry without type (type may not exist in target org)..."
      payload="$(echo "$payload" | jq 'del(.type)')"
      printf '%s' "$payload" > "$_body_tmp"
      create_result="$(gh api "repos/$TARGET_ORG/$repo_name/issues" \
        --method POST \
        --input "$_body_tmp" \
        2>/dev/null)" || create_result="FAILED"
    fi

    if [[ "$create_result" == "FAILED" ]]; then
      warn "  Failed to create issue #$src_number ('$title') in $TARGET_ORG/$repo_name"
      _upsert_issue "$state_file" "$src_number" "$src_id" "$src_state" \
        "$title" "" "" "$assignees" "failed" "" "none"
      failed_count=$((failed_count + 1))
      pause 2.0
      continue
    fi

    local tgt_number
    tgt_number="$(echo "$create_result" | jq -rs '.[0].number // empty' 2>/dev/null || true)"
    local tgt_node_id
    tgt_node_id="$(echo "$create_result" | jq -rs '.[0].node_id // empty' 2>/dev/null || true)"

    # Guard: API returned a non-issue response (e.g. secondary rate-limit 403 that
    # gh wrote to stdout before exiting non-zero, leaving create_result as partial JSON).
    if [[ -z "$tgt_number" || "$tgt_number" == "null" ]]; then
      warn "  Issue #$src_number: create did not return a valid issue number — marking failed (response: $(echo "$create_result" | head -c 120))"
      _upsert_issue "$state_file" "$src_number" "$src_id" "$src_state" \
        "$title" "" "" "$assignees" "failed" "" "none"
      failed_count=$((failed_count + 1))
      pause 2.0
      continue
    fi

    pause 4.0   # rate-limit cooldown after POST /issues

    # ---- Close issue in target if source is closed ----------------------
    if [[ "$src_state" == "closed" ]]; then
      gh api "repos/$TARGET_ORG/$repo_name/issues/$tgt_number" \
        --method PATCH \
        -f state="closed" \
        2>/dev/null || warn "  Failed to close issue #$tgt_number in $TARGET_ORG/$repo_name"
      pause 3.0   # rate-limit cooldown after PATCH /issues
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
    wrote_count=$((wrote_count + 1))
    if (( wrote_count % 10 == 0 )) && [[ "$DRY_RUN" -eq 0 ]]; then
      commit_state "mirror: checkpoint $wrote_count issue writes in $repo_name [skip ci]"
    fi
    pause 3.0   # rate-limit buffer between issues

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
    --paginate 2>/dev/null | \
    jq -rs '[.[] | select(type=="array") | .[] | select(type=="object")]')" || comments='[]'

  local total_comments
  total_comments="$(echo "$comments" | jq -r 'if type=="array" then length else 0 end' 2>/dev/null || echo 0)"

  if [[ "$total_comments" -eq 0 ]]; then
    _update_comments_status "$state_file" "$src_number" "done" 0
    return 0
  fi

  log "  Mirroring $total_comments comments for issue #$src_number -> #$tgt_number..."

  # Pre-fetch existing target comments for idempotency marker checks.
  # Also validates target issue is accessible — if gh api fails (404 deleted, 403 locked)
  # all comment POSTs would fail anyway; return early with a single diagnostic warning.
  local _tgt_comments_raw tgt_comment_bodies
  _tgt_comments_raw="$(gh api \
    "repos/$TARGET_ORG/$repo_name/issues/$tgt_number/comments?per_page=100" \
    --paginate 2>/dev/null)" || {
    warn "  Issue #$src_number: cannot access comments on target #$tgt_number in $TARGET_ORG/$repo_name — issue may be deleted, locked, or issues disabled — skipping comment sync"
    return 0
  }
  tgt_comment_bodies="$(echo "$_tgt_comments_raw" | \
    jq -rs '[.[] | select(type=="array") | .[] | select(type=="object") | .body // ""] | join("\n")')" \
    || tgt_comment_bodies=''

  # Save caller's RETURN trap before overwriting it — bash RETURN traps are shell-global.
  # Without this, when _mirror_repo_issues returns its trap fires with $_post_err_tmp unbound.
  local _prev_trap
  _prev_trap="$(trap -p RETURN 2>/dev/null || true)"
  local _post_err_tmp _body_tmp
  _post_err_tmp="$(mktemp)"
  _body_tmp="$(mktemp)"
  # SC2064: intentional — expand paths now so cleanup uses correct literal paths
  # and restores caller's trap regardless of variable scope at fire-time.
  # shellcheck disable=SC2064
  trap "rm -f -- '${_post_err_tmp}' '${_body_tmp}'; ${_prev_trap:-trap - RETURN}" RETURN

  local mirrored=0
  local posted_since_commit=0
  while IFS= read -r comment; do
    local c_id c_author c_created c_body
    c_id="$(echo      "$comment" | jq -r '.id')"
    c_author="$(echo  "$comment" | jq -r '.user.login // "unknown"')"
    c_created="$(echo "$comment" | jq -r '.created_at // ""')"
    c_body="$(echo    "$comment" | jq -r '.body // ""')"

    # Marker for idempotency on future re-runs (stored in comment body)
    local c_marker="<!-- cf-mirror-comment: $SOURCE_ORG/$repo_name#$src_number/$c_id -->"

    # Skip if already posted in a previous (possibly interrupted) run
    if [[ "$tgt_comment_bodies" == *"$c_marker"* ]]; then
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

    local c_result
    printf '%s' "$c_full_body" | jq -Rs '{"body":.}' > "$_body_tmp"
    c_result="$(gh api "repos/$TARGET_ORG/$repo_name/issues/$tgt_number/comments" \
      --method POST \
      --input "$_body_tmp" \
      2>"$_post_err_tmp")" || c_result="FAILED"

    if [[ "$c_result" == "FAILED" ]]; then
      warn "  Failed to mirror comment $c_id on issue #$src_number — $(cat "$_post_err_tmp" 2>/dev/null | head -1 || true)"
    else
      mirrored=$((mirrored + 1))
      posted_since_commit=$((posted_since_commit + 1))
      if (( posted_since_commit % 25 == 0 )) && [[ "$DRY_RUN" -eq 0 ]]; then
        _update_comments_status "$state_file" "$src_number" "in_progress" "$mirrored"
        commit_state "mirror: checkpoint issue #$src_number comments ($posted_since_commit posted) in $repo_name [skip ci]"
      fi
    fi
    pause 3.0   # rate-limit cooldown after POST /issues/{n}/comments
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

# ---------------------------------------------------------------------------
# _reconcile_issue — full re-sync of an already-mirrored issue.
# Called in continuous mode for open issues and issues that just closed.
# Syncs: title, body, labels, milestone, open/closed state, and all comments
# (adds new ones, updates edited ones).
# Body comparison uses source→target URL normalisation to avoid false positives
# from stage-07 rewrites that are already in the target.
# ---------------------------------------------------------------------------
_reconcile_issue() {
  local repo_name="$1"
  local issue_json="$2"
  local src_number="$3"
  local tgt_number="$4"
  local state_file="$5"

  local _body_tmp
  _body_tmp="$(mktemp)"
  trap 'rm -f "$_body_tmp"' RETURN

  local src_state title body labels milestone_title src_author src_created src_id assignees issue_type_name
  src_state="$(echo "$issue_json"        | jq -r '.state')"
  title="$(echo "$issue_json"            | jq -r '.title')"
  body="$(echo "$issue_json"             | jq -r '.body // ""')"
  labels="$(echo "$issue_json"           | jq -r '[.labels[].name]')"
  milestone_title="$(echo "$issue_json"  | jq -r '.milestone.title // ""')"
  src_author="$(echo "$issue_json"       | jq -r '.user.login // "unknown"')"
  src_created="$(echo "$issue_json"      | jq -r '.created_at // ""')"
  src_id="$(echo "$issue_json"           | jq -r '.id')"
  assignees="$(echo "$issue_json"        | jq -r '[.assignees[].login]')"
  issue_type_name="$(echo "$issue_json"  | jq -r '.type.name // ""')"
  local src_url="https://github.com/$SOURCE_ORG/$repo_name/issues/$src_number"
  local marker="<!-- cf-mirror: $SOURCE_ORG/$repo_name#$src_number -->"

  # ---- Rebuild body from current source content ----------------------------
  local encoded_body
  encoded_body="$(echo "$body" | _encode_at_mentions)"
  local attribution="> 🔗 **Mirrored from** [$SOURCE_ORG/$repo_name#$src_number]($src_url)
> Originally opened by **${src_author}** on ${src_created}"
  local new_body
  if [[ -n "$body" ]]; then
    new_body="${attribution}

---

${encoded_body}

---
${marker}"
  else
    new_body="${attribution}

---
${marker}"
  fi

  # ---- Fetch current target issue ------------------------------------------
  local tgt_json
  tgt_json="$(gh api "repos/$TARGET_ORG/$repo_name/issues/$tgt_number" \
    2>/dev/null | jq -rs '.[0] // {}')" || tgt_json='{}'
  local tgt_title tgt_body tgt_state tgt_milestone_num tgt_node_id tgt_type_name
  tgt_title="$(echo "$tgt_json"         | jq -r '.title // ""'          2>/dev/null || true)"
  tgt_body="$(echo "$tgt_json"          | jq -r '.body // ""'           2>/dev/null || true)"
  tgt_state="$(echo "$tgt_json"         | jq -r '.state // "open"'      2>/dev/null || true)"
  tgt_milestone_num="$(echo "$tgt_json" | jq -r '.milestone.number // "null"' 2>/dev/null || echo 'null')"
  tgt_node_id="$(echo "$tgt_json"       | jq -r '.node_id // ""'        2>/dev/null || true)"
  tgt_type_name="$(echo "$tgt_json"     | jq -r '.type.name // ""'      2>/dev/null || true)"
  pause 1.0

  # ---- Resolve target milestone number from source title -------------------
  local new_milestone_number="null"
  if [[ -n "$milestone_title" ]]; then
    new_milestone_number="$(gh api \
      "repos/$TARGET_ORG/$repo_name/milestones?per_page=100" 2>/dev/null | \
      jq -r --arg t "$milestone_title" '.[] | select(.title == $t) | .number' \
      2>/dev/null | head -1 || true)"
    new_milestone_number="${new_milestone_number:-null}"
  fi

  # ---- Compute what needs to change ----------------------------------------
  local patch_payload="{}" body_changed=0

  # Title
  if [[ "$title" != "$tgt_title" ]]; then
    patch_payload="$(echo "$patch_payload" | jq --arg v "$title" '.title = $v')"
  fi

  # Body — normalise source-org URLs before comparing so stage-07 rewrites
  # already in the target don't cause a spurious PATCH on every run.
  local new_body_norm tgt_body_norm
  new_body_norm="$(echo "$new_body" | sed "s|https://github\.com/${SOURCE_ORG}/|https://github.com/${TARGET_ORG}/|g")"
  tgt_body_norm="$(echo "$tgt_body" | sed "s|https://github\.com/${SOURCE_ORG}/|https://github.com/${TARGET_ORG}/|g")"
  if [[ "$new_body_norm" != "$tgt_body_norm" ]]; then
    patch_payload="$(printf '%s' "$new_body" | \
      jq -Rs --argjson base "$patch_payload" '$base + {"body":.}')"
    body_changed=1
  fi

  # Labels — compare sorted; always include to handle removals
  local src_labels_sorted tgt_labels_sorted
  src_labels_sorted="$(echo "$labels"   | jq -c 'sort'                   2>/dev/null || echo '[]')"
  tgt_labels_sorted="$(echo "$tgt_json" | jq -c '[.labels[].name] | sort' 2>/dev/null || echo '[]')"
  if [[ "$src_labels_sorted" != "$tgt_labels_sorted" ]]; then
    patch_payload="$(echo "$patch_payload" | jq --argjson v "$labels" '.labels = $v')"
  fi

  # Milestone — compare numbers
  if [[ "$new_milestone_number" != "$tgt_milestone_num" ]]; then
    patch_payload="$(echo "$patch_payload" | jq --argjson v "${new_milestone_number}" '.milestone = $v')"
  fi

  # State (open/closed)
  if [[ "$src_state" != "$tgt_state" ]]; then
    patch_payload="$(echo "$patch_payload" | jq --arg v "$src_state" '.state = $v')"
  fi

  # Issue type (Bug/Feature/Task) — reconcile if source has a type and target differs.
  if [[ -n "$issue_type_name" && "$issue_type_name" != "$tgt_type_name" ]]; then
    patch_payload="$(echo "$patch_payload" | jq --arg v "$issue_type_name" '.type = $v')"
  fi

  # ---- Apply PATCH if anything changed -------------------------------------
  if [[ "$patch_payload" != "{}" ]]; then
    printf '%s' "$patch_payload" > "$_body_tmp"
    gh api "repos/$TARGET_ORG/$repo_name/issues/$tgt_number" \
      --method PATCH \
      --input "$_body_tmp" \
      2>/dev/null || warn "  Failed to reconcile issue $repo_name#$src_number → #$tgt_number"
    log "  Reconciled #$src_number → #$tgt_number ($(echo "$patch_payload" | jq -r 'keys | join(", ")'))"
    pause 3.0
    [[ "$body_changed" -eq 1 ]] && _clear_crossref_record "$repo_name" "$tgt_number"
  fi

  # ---- Reconcile comments (add new, update edited) -------------------------
  _reconcile_issue_comments "$repo_name" "$src_number" "$tgt_number" "$state_file"

  # ---- Update state file with current source values ------------------------
  local assignees_count assignees_status
  assignees_count="$(echo "$assignees" | jq 'length')"
  assignees_status="none"
  [[ "$assignees_count" -gt 0 ]] && assignees_status="pending"
  _upsert_issue "$state_file" "$src_number" "$src_id" "$src_state" \
    "$title" "$tgt_number" "$tgt_node_id" "$assignees" "mirrored" "$(now)" "$assignees_status"
}

# ---------------------------------------------------------------------------
# _reconcile_issue_comments — add new comments and update edited ones.
# For each source comment the corresponding target comment is found by its
# embedded marker.  Bodies are normalised (source-org → target-org URL
# replacement) before comparison so stage-07 rewrites don't cause
# unnecessary PATCHes.  The raw (source-org) body is written to target so
# that stage 07 can rewrite cross-references on its next run.
# ---------------------------------------------------------------------------
_reconcile_issue_comments() {
  local repo_name="$1"
  local src_number="$2"
  local tgt_number="$3"
  local state_file="$4"

  local _body_tmp
  _body_tmp="$(mktemp)"
  trap 'rm -f "$_body_tmp"' RETURN

  local comments
  comments="$(ghsrc api \
    "repos/$SOURCE_ORG/$repo_name/issues/$src_number/comments?per_page=100" \
    --paginate 2>/dev/null | \
    jq -rs '[.[] | select(type=="array") | .[] | select(type=="object")]')" || comments='[]'

  local total_comments
  total_comments="$(echo "$comments" | jq -r 'if type=="array" then length else 0 end' \
    2>/dev/null || echo 0)"

  if [[ "$total_comments" -eq 0 ]]; then
    _update_comments_status "$state_file" "$src_number" "done" 0
    return 0
  fi

  log "  Reconciling $total_comments comments for issue #$src_number..."

  # Pre-fetch target comments once — need id + body for the update path
  local tgt_comments
  tgt_comments="$(gh api \
    "repos/$TARGET_ORG/$repo_name/issues/$tgt_number/comments?per_page=100" \
    --paginate 2>/dev/null | \
    jq -rs '[.[] | select(type=="array") | .[] | select(type=="object") | {id, body}]')" || tgt_comments='[]'

  local mirrored=0

  while IFS= read -r c; do
    local c_id c_author c_created c_body c_marker c_full_body
    c_id="$(echo      "$c" | jq -r '.id')"
    c_author="$(echo  "$c" | jq -r '.user.login // "unknown"')"
    c_created="$(echo "$c" | jq -r '.created_at // ""')"
    c_body="$(echo    "$c" | jq -r '.body // ""' | _encode_at_mentions)"
    c_marker="<!-- cf-mirror-comment: $SOURCE_ORG/$repo_name#$src_number/$c_id -->"
    c_full_body="**${c_author}** commented on ${c_created}:

---

${c_body}

${c_marker}"

    # Find matching target comment by marker
    local tgt_c_id
    tgt_c_id="$(echo "$tgt_comments" | jq -r \
      --arg m "$c_marker" \
      '.[] | select(.body | contains($m)) | .id' 2>/dev/null | head -1 || true)"

    if [[ -n "$tgt_c_id" && "$tgt_c_id" != "null" ]]; then
      # Comment exists — compare normalised bodies
      local tgt_c_body new_norm tgt_norm
      tgt_c_body="$(echo "$tgt_comments" | jq -r \
        --argjson id "$tgt_c_id" '.[] | select(.id == $id) | .body // ""' \
        2>/dev/null || true)"
      new_norm="$(echo "$c_full_body" | sed "s|https://github\.com/${SOURCE_ORG}/|https://github.com/${TARGET_ORG}/|g")"
      tgt_norm="$(echo "$tgt_c_body"  | sed "s|https://github\.com/${SOURCE_ORG}/|https://github.com/${TARGET_ORG}/|g")"
      if [[ "$new_norm" != "$tgt_norm" ]]; then
        printf '%s' "$c_full_body" | jq -Rs '{"body":.}' > "$_body_tmp"
        gh api "repos/$TARGET_ORG/$repo_name/issues/comments/$tgt_c_id" \
          --method PATCH \
          --input "$_body_tmp" \
          2>/dev/null || warn "  Failed to update comment $c_id on #$src_number"
        pause 3.0
      fi
      mirrored=$((mirrored + 1))
    else
      # New comment — create it
      local c_result
      printf '%s' "$c_full_body" | jq -Rs '{"body":.}' > "$_body_tmp"
      c_result="$(gh api "repos/$TARGET_ORG/$repo_name/issues/$tgt_number/comments" \
        --method POST \
        --input "$_body_tmp" \
        2>/dev/null)" || c_result="FAILED"
      [[ "$c_result" != "FAILED" ]] && mirrored=$((mirrored + 1)) || \
        warn "  Failed to create comment $c_id on #$src_number"
      pause 3.0
    fi
  done < <(echo "$comments" | jq -c '.[]' 2>/dev/null || true)

  _update_comments_status "$state_file" "$src_number" "done" "$mirrored"
  ok "  Reconciled $mirrored/$total_comments comments for issue #$src_number"
}

# ===========================================================================
# Export / Import helpers (MIRROR_MODE = export | import)
# ===========================================================================

# _build_issue_body <repo> <src_number> <src_author> <src_created> <raw_body>
# Emits the full target issue body (attribution + encoded body + marker) on
# stdout. Byte-for-byte identical to the full-mode create path so re-runs and
# stage 07 cross-reference rewrites behave the same regardless of mode.
_build_issue_body() {
  local repo_name="$1" src_number="$2" src_author="$3" src_created="$4" body="$5"
  local src_url="https://github.com/$SOURCE_ORG/$repo_name/issues/$src_number"
  local marker="<!-- cf-mirror: $SOURCE_ORG/$repo_name#$src_number -->"
  local attribution="> 🔗 **Mirrored from** [$SOURCE_ORG/$repo_name#$src_number]($src_url)
> Originally opened by **${src_author}** on ${src_created}"
  local encoded_body
  encoded_body="$(echo "$body" | _encode_at_mentions)"
  if [[ -n "$body" ]]; then
    printf '%s\n\n---\n\n%s\n\n---\n%s' "$attribution" "$encoded_body" "$marker"
  else
    printf '%s\n\n---\n%s' "$attribution" "$marker"
  fi
}

# _build_comment_body <repo> <src_number> <c_id> <c_author> <c_created> <c_body>
# Emits the full target comment body (attribution header + encoded body +
# marker). Matches the full-mode comment format exactly.
_build_comment_body() {
  local repo_name="$1" src_number="$2" c_id="$3" c_author="$4" c_created="$5" c_body="$6"
  local c_marker="<!-- cf-mirror-comment: $SOURCE_ORG/$repo_name#$src_number/$c_id -->"
  local encoded
  encoded="$(echo "$c_body" | _encode_at_mentions)"
  printf '**%s** commented on %s:\n\n---\n\n%s\n\n%s' \
    "$c_author" "$c_created" "$encoded" "$c_marker"
}

# ---------------------------------------------------------------------------
# Export: fetch raw source issues + comments, serialize into the state file.
# NEVER contacts the target org.
# ---------------------------------------------------------------------------
_export_repo_issues() {
  local repo_name="$1"
  local state_file="$STATE_DIR/$repo_name.yaml"
  state_unsplit "$state_file"   # reassemble parts from a prior run before reading/merging
  state_init "$state_file" "05-mirror-issues"

  log "  [export] Fetching issues from $SOURCE_ORG/$repo_name..."
  local issues_open issues_closed all_issues
  issues_open="$(ghsrc api \
    "repos/$SOURCE_ORG/$repo_name/issues?state=open&per_page=100" \
    --paginate 2>/dev/null | \
    jq -rs '[.[] | select(type=="array") | .[] | select(type=="object")]')" || issues_open='[]'
  issues_closed="$(ghsrc api \
    "repos/$SOURCE_ORG/$repo_name/issues?state=closed&per_page=100" \
    --paginate 2>/dev/null | \
    jq -rs '[.[] | select(type=="array") | .[] | select(type=="object")]')" || issues_closed='[]'
  all_issues="$(printf '%s\n' "$issues_open" "$issues_closed" | \
    jq -rs '[.[] | select(type=="array") | .[] | select(type=="object") | select(.pull_request == null)] | unique_by(.id)')"

  local total_issues
  total_issues="$(echo "$all_issues" | jq -r 'if type=="array" then length else 0 end' 2>/dev/null || echo 0)"
  log "  [export] Found $total_issues issues in $repo_name"
  if [[ "$total_issues" -eq 0 ]]; then
    state_update_stats "$state_file"
    return 0
  fi

  local exported=0
  while IFS= read -r issue; do
    local src_number
    src_number="$(echo "$issue" | jq -r '.number')"

    local comments
    comments="$(ghsrc api \
      "repos/$SOURCE_ORG/$repo_name/issues/$src_number/comments?per_page=100" \
      --paginate 2>/dev/null | \
      jq -rs '[.[] | select(type=="array") | .[] | select(type=="object")]')" || comments='[]'

    _upsert_issue_export "$state_file" "$issue" "$comments"
    exported=$((exported + 1))
    (( exported % 25 == 0 )) && log "  [export] Serialized $exported/$total_issues issues..."
    if (( exported % 10 == 0 )) && [[ "$DRY_RUN" -eq 0 ]]; then
      # Checkpoint: split before committing so a file that has already grown past
      # the GitHub limit mid-run can still be pushed, then reassemble to continue
      # the loop (the in-memory upsert logic needs the whole file).
      state_split_if_needed "$state_file"
      commit_state "mirror: export checkpoint $exported issues in $repo_name [skip ci]"
      state_unsplit "$state_file"
    fi
    pause 0.3
  done < <(echo "$all_issues" | jq -c '.[]')

  state_update_stats "$state_file"
  state_split_if_needed "$state_file"   # split into parts if > MAX_STATE_FILE_MB
  ok "  [export] Serialized $exported issues for $repo_name"
}

# _upsert_issue_export <state_file> <raw_issue_json> <raw_comments_json>
# Stores the raw issue + comments plus index fields. Large JSON is passed to jq
# via --slurpfile (file input), never as an OS argument, to stay ARG_MAX-safe
# (RC-6). Import progress fields are preserved if the item already exists.
_upsert_issue_export() {
  local state_file="$1" issue="$2" comments="$3"
  local src_number src_id src_state title assignees
  src_number="$(echo "$issue" | jq -r '.number')"
  src_id="$(echo "$issue" | jq -r '.id')"
  src_state="$(echo "$issue" | jq -r '.state')"
  title="$(echo "$issue" | jq -r '.title')"
  assignees="$(echo "$issue" | jq -c '[.assignees[].login]')"
  local assignees_status="none"
  [[ "$(echo "$assignees" | jq 'length')" -gt 0 ]] && assignees_status="pending"

  local _issue_tmp _comments_tmp _rec_tmp _state_tmp
  _issue_tmp="$(mktemp)"; _comments_tmp="$(mktemp)"
  _rec_tmp="$(mktemp)";  _state_tmp="$(mktemp)"
  printf '%s' "$issue"    > "$_issue_tmp"
  printf '%s' "$comments" > "$_comments_tmp"

  jq -n \
    --slurpfile issue_arr    "$_issue_tmp" \
    --slurpfile comments_arr "$_comments_tmp" \
    --argjson src_num "$src_number" \
    --argjson src_id  "$src_id" \
    --arg     src_st  "$src_state" \
    --arg     title   "$title" \
    --argjson assignees "$assignees" \
    --arg     ast     "$assignees_status" \
    '{
      source_number:        $src_num,
      source_id:            $src_id,
      source_state:         $src_st,
      target_number:        null,
      target_node_id:       null,
      title:                $title,
      assignees:            $assignees,
      status:               "exported",
      mirrored_at:          null,
      assignees_status:     $ast,
      assignees_applied_at: null,
      comments_status:      "none",
      comments_mirrored:    0,
      source_data:          $issue_arr[0],
      source_comments:      $comments_arr[0]
    }' > "$_rec_tmp"

  jq --argjson sn "$src_number" --slurpfile recarr "$_rec_tmp" \
    'def rec: $recarr[0];
     if (.items | map(select(.source_number == $sn)) | length) > 0
     then .items = [.items[] | if .source_number == $sn then
       . as $old | rec
       | .target_number     = ($old.target_number)
       | .target_node_id    = ($old.target_node_id)
       | .status            = (if ($old.target_number != null) then $old.status else "exported" end)
       | .mirrored_at       = ($old.mirrored_at)
       | .comments_status   = ($old.comments_status   // "none")
       | .comments_mirrored = ($old.comments_mirrored // 0)
     else . end]
     else .items += [rec]
     end' \
    "$state_file" > "$_state_tmp" && mv "$_state_tmp" "$state_file"

  rm -f "$_issue_tmp" "$_comments_tmp" "$_rec_tmp" "$_state_tmp"
}

# ---------------------------------------------------------------------------
# Import: read serialized state files and create issues in the target.
# NEVER contacts the source org. Resumable via local state only (no target reads).
# ---------------------------------------------------------------------------
_import_all_issues() {
  # Discover repos from whole files AND split-part manifests (a freshly-pulled
  # repo may exist only as <repo>.yaml.partNN + manifest until reassembled).
  local repo_names
  repo_names="$(state_repo_names "$STATE_DIR")"
  if [[ -z "$repo_names" ]]; then
    warn "No state files in $STATE_DIR — run MIRROR_MODE=export first"
    return 0
  fi
  # B1 FIX: SOURCE_ORG is needed in import mode to construct correct cf-mirror markers
  # and attribution headers (e.g. <!-- cf-mirror: SOURCE_ORG/repo#N -->).  A wrong or
  # empty SOURCE_ORG produces broken markers that break idempotency for future full-mode
  # runs (the marker won't match, causing duplicate issue creation). SOURCE_ORG is stored
  # in .meta.source_org at export time; auto-derive from the first repo's state if not set.
  if [[ -z "${SOURCE_ORG:-}" ]]; then
    local _first_repo
    _first_repo="$(echo "$repo_names" | head -1)"
    state_unsplit "$STATE_DIR/$_first_repo.yaml"   # ensure a whole file to read meta from
    SOURCE_ORG="$(jq -r '.meta.source_org // empty' "$STATE_DIR/$_first_repo.yaml" 2>/dev/null || true)"
    [[ -n "$SOURCE_ORG" ]] && \
      log "  [import] Derived SOURCE_ORG='$SOURCE_ORG' from state meta"
    [[ -z "$SOURCE_ORG" ]] && \
      warn "  [import] SOURCE_ORG unset and not in state meta — cf-mirror markers will be empty, idempotency will break"
  fi
  log "Importing issues from $(echo "$repo_names" | grep -c .) repo state file(s)"

  # ---- Precompute total items across all repos for the progress/ETA engine ----
  # Export already serialized every issue, so the total is known up front. We
  # reassemble each repo (idempotent; _import_repo_issues would do it anyway) and
  # count .items so % and ETA are accurate across the whole multi-repo run.
  local _total_issues=0 _rn
  while IFS= read -r _rn; do
    [[ -z "$_rn" ]] && continue
    state_unsplit "$STATE_DIR/$_rn.yaml"
    local _c
    _c="$(jq '.items | length' "$STATE_DIR/$_rn.yaml" 2>/dev/null || echo 0)"
    _total_issues=$(( _total_issues + _c ))
  done < <(echo "$repo_names")
  progress_begin "$_total_issues" "issues"

  local repo_name
  while IFS= read -r repo_name; do
    [[ -z "$repo_name" ]] && continue
    log "Importing issues for $repo_name..."
    _import_repo_issues "$repo_name"
    pause 2.0
  done < <(echo "$repo_names")

  progress_end
  apirate_report   # final rolling-60m API call summary by category
}

_import_repo_issues() {
  local repo_name="$1"
  local state_file="$STATE_DIR/$repo_name.yaml"
  state_unsplit "$state_file"   # reassemble parts (freshly pulled) into the whole file
  [[ -f "$state_file" ]] || { warn "  No state file for $repo_name"; return 0; }

  local _body_tmp
  _body_tmp="$(mktemp)"
  trap 'rm -f "$_body_tmp"' RETURN

  local imported=0 skipped=0 failed=0 wrote=0
  while IFS= read -r item; do
    local src_number status tgt_existing comments_status
    src_number="$(echo "$item" | jq -r '.source_number')"
    status="$(echo "$item" | jq -r '.status // empty')"
    tgt_existing="$(echo "$item" | jq -r '.target_number // empty')"
    comments_status="$(echo "$item" | jq -r '.comments_status // "none"')"

    # Advance the cross-repo progress/ETA counter once per item (every item is a
    # unit of work whether it gets created, skipped, or fails below).
    progress_tick 1 "$repo_name"

    # Already imported — reconcile (CONTINUOUS) or finish comment sync only.
    if [[ -n "$tgt_existing" && "$tgt_existing" != "null" ]]; then
      if [[ "${CONTINUOUS:-false}" == "true" ]]; then
        # CONTINUOUS mode: reconcile title/body/labels/milestone/type from source_data.
        # This is how already-migrated issues get their type (and other fields) patched.
        local _src_data
        _src_data="$(echo "$item" | jq -c '.source_data // {}')"
        if [[ -n "$_src_data" && "$_src_data" != "{}" ]]; then
          _reconcile_issue "$repo_name" "$_src_data" "$src_number" "$tgt_existing" "$state_file"
        fi
      elif [[ "$comments_status" != "done" ]]; then
        _import_issue_comments "$repo_name" "$item" "$tgt_existing" "$state_file"
      fi
      skipped=$((skipped + 1))
      continue
    fi

    # Nothing importable (e.g. item failed during export).
    if [[ "$status" != "exported" ]]; then
      skipped=$((skipped + 1))
      continue
    fi

    if dry_run_skip "import issue #$src_number into $TARGET_ORG/$repo_name"; then
      imported=$((imported + 1)); continue
    fi

    local issue src_state title body assignees labels milestone_title src_author src_created tgt_node_id issue_type_name
    issue="$(echo "$item" | jq -c '.source_data')"
    src_state="$(echo "$issue" | jq -r '.state')"
    title="$(echo "$issue" | jq -r '.title')"
    body="$(echo "$issue" | jq -r '.body // ""')"
    assignees="$(echo "$issue" | jq -c '[.assignees[].login]')"
    labels="$(echo "$issue" | jq -c '[.labels[].name]')"
    milestone_title="$(echo "$issue" | jq -r '.milestone.title // ""')"
    src_author="$(echo "$issue" | jq -r '.user.login // "unknown"')"
    src_created="$(echo "$issue" | jq -r '.created_at // ""')"
    # Issue type (Bug / Feature / Task etc.) — added to GitHub REST API in 2024.
    issue_type_name="$(echo "$issue" | jq -r '.type.name // ""')"

    local full_body
    full_body="$(_build_issue_body "$repo_name" "$src_number" "$src_author" "$src_created" "$body")"

    # Resolve target milestone number from the stored milestone title.
    local milestone_number=""
    if [[ -n "$milestone_title" ]]; then
      milestone_number="$(gh api \
        "repos/$TARGET_ORG/$repo_name/milestones?per_page=100" 2>/dev/null | \
        jq -r --arg t "$milestone_title" '.[] | select(.title == $t) | .number' \
        | head -1 || true)"
    fi

    local payload
    payload="$(printf '%s' "$full_body" | jq -Rs \
      --arg title "$title" --argjson labels "$labels" \
      '{"title":$title,"body":.,"labels":$labels}')"
    if [[ -n "$milestone_number" && "$milestone_number" != "null" ]]; then
      payload="$(echo "$payload" | jq --argjson ms "$milestone_number" '.milestone = $ms')"
    fi
    # Include issue type (Bug/Feature/Task) — GitHub REST API supports this since 2024.
    # Pass by name so it works even if the target org assigned different type IDs.
    if [[ -n "$issue_type_name" ]]; then
      payload="$(echo "$payload" | jq --arg t "$issue_type_name" '.type = $t')"
    fi

    local create_result
    printf '%s' "$payload" > "$_body_tmp"
    create_result="$(gh api "repos/$TARGET_ORG/$repo_name/issues" \
      --method POST --input "$_body_tmp" 2>/dev/null)" || create_result="FAILED"

    if echo "$create_result" | jq -e '.message // "" | test("Validation Failed")' &>/dev/null; then
      warn "  Issue #$src_number: retry without labels..."
      payload="$(echo "$payload" | jq 'del(.labels)')"
      printf '%s' "$payload" > "$_body_tmp"
      create_result="$(gh api "repos/$TARGET_ORG/$repo_name/issues" \
        --method POST --input "$_body_tmp" 2>/dev/null)" || create_result="FAILED"
    fi
    if echo "$create_result" | jq -e '.message // "" | test("Validation Failed")' &>/dev/null; then
      warn "  Issue #$src_number: retry without milestone..."
      payload="$(echo "$payload" | jq 'del(.milestone)')"
      printf '%s' "$payload" > "$_body_tmp"
      create_result="$(gh api "repos/$TARGET_ORG/$repo_name/issues" \
        --method POST --input "$_body_tmp" 2>/dev/null)" || create_result="FAILED"
    fi
    if echo "$create_result" | jq -e '.message // "" | test("Validation Failed")' &>/dev/null; then
      warn "  Issue #$src_number: retry without type (type may not exist in target org)..."
      payload="$(echo "$payload" | jq 'del(.type)')"
      printf '%s' "$payload" > "$_body_tmp"
      create_result="$(gh api "repos/$TARGET_ORG/$repo_name/issues" \
        --method POST --input "$_body_tmp" 2>/dev/null)" || create_result="FAILED"
    fi

    if [[ "$create_result" == "FAILED" ]]; then
      warn "  Failed to import issue #$src_number ('$title') into $TARGET_ORG/$repo_name"
      failed=$((failed + 1)); pause 2.0; continue
    fi

    local tgt_number
    tgt_number="$(echo "$create_result" | jq -rs '.[0].number // empty' 2>/dev/null || true)"
    tgt_node_id="$(echo "$create_result" | jq -rs '.[0].node_id // empty' 2>/dev/null || true)"
    if [[ -z "$tgt_number" || "$tgt_number" == "null" ]]; then
      warn "  Issue #$src_number: import did not return a valid number — marking failed"
      failed=$((failed + 1)); pause 2.0; continue
    fi
    pause 4.0

    if [[ "$src_state" == "closed" ]]; then
      gh api "repos/$TARGET_ORG/$repo_name/issues/$tgt_number" \
        --method PATCH -f state="closed" 2>/dev/null || \
        warn "  Failed to close issue #$tgt_number in $TARGET_ORG/$repo_name"
      pause 3.0
    fi
    ok "  Imported issue #$src_number -> #$tgt_number in $TARGET_ORG/$repo_name"

    local assignees_status="none"
    [[ "$(echo "$assignees" | jq 'length')" -gt 0 ]] && assignees_status="pending"
    _mark_issue_imported "$state_file" "$src_number" "$tgt_number" "$tgt_node_id" "$assignees_status"

    # Re-read the freshly-updated item so the comments fn sees comments_mirrored.
    local updated_item
    updated_item="$(jq -c --argjson n "$src_number" \
      '.items[] | select(.source_number == $n)' "$state_file" 2>/dev/null | head -1)"
    _import_issue_comments "$repo_name" "$updated_item" "$tgt_number" "$state_file"

    imported=$((imported + 1)); wrote=$((wrote + 1))
    if (( wrote % 10 == 0 )) && [[ "$DRY_RUN" -eq 0 ]]; then
      commit_state "mirror: import checkpoint $wrote issues in $repo_name [skip ci]"
    fi
    pause 3.0
  done < <(state_items "$state_file")

  state_update_stats "$state_file"
  ok "  [import] $repo_name: imported=$imported skipped=$skipped failed=$failed"
}

# _mark_issue_imported — patch an existing item in place after a successful
# target create, preserving the serialized source_data / source_comments.
_mark_issue_imported() {
  local state_file="$1" src_number="$2" tgt_number="$3" tgt_node_id="$4" assignees_status="$5"
  state_update "$state_file" \
    '.items = [.items[] | if .source_number == $sn then
       .target_number = $tn
       | .target_node_id = (if $nid == "" then null else $nid end)
       | .status = "mirrored"
       | .mirrored_at = $mat
       | .assignees_status = $ast
     else . end]' \
    --argjson sn "$src_number" --argjson tn "$tgt_number" \
    --arg nid "$tgt_node_id" --arg mat "$(now)" --arg ast "$assignees_status"
}

# _import_issue_comments <repo> <item_json> <tgt_number> <state_file>
# Posts serialized source comments to the target. Resumable WITHOUT reading the
# target: comments_mirrored records how many were posted, and a re-run skips that
# many from the front. Index-resume can never duplicate (worst case it under-posts
# after a mid-stream failure, which is logged).
_import_issue_comments() {
  local repo_name="$1" item="$2" tgt_number="$3" state_file="$4"
  local src_number comments total already
  src_number="$(echo "$item" | jq -r '.source_number')"
  comments="$(echo "$item" | jq -c '.source_comments // []')"
  total="$(echo "$comments" | jq 'length')"
  already="$(echo "$item" | jq -r '.comments_mirrored // 0')"

  if [[ "$total" -eq 0 ]]; then
    _update_comments_status "$state_file" "$src_number" "done" 0
    return 0
  fi

  log "  [import] Posting comments for issue #$src_number -> #$tgt_number ($already/$total already done)..."

  local _body_tmp _post_err_tmp _prev_trap
  _prev_trap="$(trap -p RETURN 2>/dev/null || true)"
  _body_tmp="$(mktemp)"; _post_err_tmp="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f -- '${_body_tmp}' '${_post_err_tmp}'; ${_prev_trap:-trap - RETURN}" RETURN

  local idx=0 posted="$already" failed=0
  while IFS= read -r c; do
    idx=$((idx + 1))
    (( idx <= already )) && continue   # resume: skip comments posted in a prior run
    local c_id c_author c_created c_body c_full_body c_result
    c_id="$(echo "$c" | jq -r '.id')"
    c_author="$(echo "$c" | jq -r '.user.login // "unknown"')"
    c_created="$(echo "$c" | jq -r '.created_at // ""')"
    c_body="$(echo "$c" | jq -r '.body // ""')"
    c_full_body="$(_build_comment_body "$repo_name" "$src_number" "$c_id" "$c_author" "$c_created" "$c_body")"

    printf '%s' "$c_full_body" | jq -Rs '{"body":.}' > "$_body_tmp"
    c_result="$(gh api "repos/$TARGET_ORG/$repo_name/issues/$tgt_number/comments" \
      --method POST --input "$_body_tmp" 2>"$_post_err_tmp")" || c_result="FAILED"
    if [[ "$c_result" == "FAILED" ]]; then
      # M1 FIX: record the failure and stop advancing the resumable counter so the
      # PR/issue is NOT marked "done" with comments missing (which would make a
      # re-run skip it permanently). Re-run resumes from the successful prefix.
      failed=$((failed + 1))
      warn "  Failed to import comment $c_id on issue #$src_number — $(head -1 "$_post_err_tmp" 2>/dev/null || true)"
    elif (( failed == 0 )); then
      posted=$((posted + 1))
      if (( posted % 25 == 0 )) && [[ "$DRY_RUN" -eq 0 ]]; then
        _update_comments_status "$state_file" "$src_number" "in_progress" "$posted"
        commit_state "mirror: import checkpoint issue #$src_number comments ($posted) in $repo_name [skip ci]"
      fi
    fi
    pause 3.0
  done < <(echo "$comments" | jq -c '.[]')

  # M1 FIX: only "done" when all comments posted; else leave "in_progress" to retry.
  if (( failed == 0 )); then
    _update_comments_status "$state_file" "$src_number" "done" "$posted"
    ok "  [import] Posted comments for issue #$src_number ($posted/$total)"
  else
    _update_comments_status "$state_file" "$src_number" "in_progress" "$posted"
    warn "  [import] Issue #$src_number comments INCOMPLETE: $posted/$total posted, $failed failed — left in_progress, re-run to retry"
  fi
}

main "$@"
