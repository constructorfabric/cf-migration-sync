#!/usr/bin/env bash
# mirror/stages/07-rewrite-cross-references.sh
# Post-process all mirrored issue/PR bodies and comments to rewrite
# internal links that still point at the source org.
#
# MUST run after stages 05 and 06 are complete — it needs their state files
# to build the exact source_number → target_number mapping per repo.
#
# Rewrites applied to every body/comment that contains source-org content:
#
#   1. https://github.com/SOURCE/REPO/issues/N
#         → https://github.com/TARGET/REPO/issues/M   (M from issue map)
#
#   2. https://github.com/SOURCE/REPO/pull/N
#         → https://github.com/TARGET/REPO/issues/M   (PRs become issues;
#              /pull/ changes to /issues/; M from PR map)
#
#   3. https://github.com/SOURCE/REPO/commit/SHA
#         → https://github.com/TARGET/REPO/commit/SHA  (SHA unchanged)
#
#   4. https://github.com/SOURCE/... (any other source-org URL)
#         → https://github.com/TARGET/...
#
#   5. SOURCE/REPO#N  (cross-repo mention)
#         → TARGET/REPO#M
#
#   6. Bare #N  (same-repo relative reference, outside code fences)
#         → #M   (using combined issue+PR number map for the current repo)
#
# NOT rewritten (intentionally preserved):
#   - Attribution lines produced by stages 05/06 (contain "Mirrored from",
#     "<!-- cf-mirror", "> 🔗", "> Originally opened by", "> **Author:**")
#   - Content inside fenced code blocks (``` or ~~~)
#
# If a number N has no mapping (issue failed to mirror, or belongs to a
# different org entirely), the number is left unchanged while the org name
# is still rewritten.
#
# Idempotency: bodies that no longer contain source-org URLs produce
# new_body == current_body → no PATCH is issued.  Re-running is always safe.
#
# State file: state/rewrite-crossrefs.yaml
# Tracks per-item status: rewritten | no_change | failed
#
# Usage:
#   SOURCE_ORG=cyberfabric TARGET_ORG=constructorfabric \
#   GH_TOKEN=xxx GH_TOKEN_SOURCE=xxx \
#   ./mirror/stages/07-rewrite-cross-references.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

TARGET_ORG="${TARGET_ORG:-constructorfabric}"
STATE_FILE="$REPO_ROOT/state/rewrite-crossrefs.yaml"

# Temp file paths — set in main(), cleaned up via trap
REWRITE_PY=""
MAPS_FILE=""

# ---------------------------------------------------------------------------
main() {
  check_dry_run "$@"
  preflight

  log "Stage 07 — rewrite-cross-references starting"
  state_init "$STATE_FILE" "07-rewrite-cross-references"

  # ---- Write Python rewrite helper to temp file ---------------------------
  REWRITE_PY="$(mktemp /tmp/cf-rewrite.XXXXX.py)"
  MAPS_FILE="$(mktemp /tmp/cf-maps.XXXXX.json)"
  trap 'rm -f "$REWRITE_PY" "$MAPS_FILE"' EXIT
  _write_rewrite_script "$REWRITE_PY"

  # ---- Build source → target number maps from stage 05/06 state files -----
  log "Building number maps from stage 05/06 state files..."
  local number_maps
  number_maps="$(build_number_maps)"
  local repo_count
  repo_count="$(echo "$number_maps" | jq 'keys | length')"
  log "  Maps ready for $repo_count repos"
  echo "$number_maps" > "$MAPS_FILE"

  # ---- Process issues (from state/issues/*.yaml) --------------------------
  local found_issues=0
  for sf in "$REPO_ROOT/state/issues/"*.yaml; do
    [[ -f "$sf" ]] || continue
    found_issues=$((found_issues + 1))
  done

  if [[ "$found_issues" -gt 0 ]]; then
    log "Processing issue bodies and comments ($found_issues repos)..."
    for sf in "$REPO_ROOT/state/issues/"*.yaml; do
      [[ -f "$sf" ]] || continue
      local repo_name
      repo_name="$(basename "$sf" .yaml)"
      _rewrite_repo_items "$repo_name" "issues" "$sf"
    done
  else
    log "No issue state files found — skipping (run stage 05 first)"
  fi

  # ---- Process PR-backed issues (from state/prs/*.yaml) -------------------
  local found_prs=0
  for sf in "$REPO_ROOT/state/prs/"*.yaml; do
    [[ -f "$sf" ]] || continue
    found_prs=$((found_prs + 1))
  done

  if [[ "$found_prs" -gt 0 ]]; then
    log "Processing PR issue bodies and comments ($found_prs repos)..."
    for sf in "$REPO_ROOT/state/prs/"*.yaml; do
      [[ -f "$sf" ]] || continue
      local repo_name
      repo_name="$(basename "$sf" .yaml)"
      _rewrite_repo_items "$repo_name" "prs" "$sf"
    done
  else
    log "No PR state files found — skipping (run stage 06 first)"
  fi

  # ---- Stats and commit ---------------------------------------------------
  state_update_stats "$STATE_FILE"

  local total synced failed
  total="$(jq '.stats.total'   "$STATE_FILE")"
  synced="$(jq '.stats.synced' "$STATE_FILE")"
  failed="$(jq '.stats.failed' "$STATE_FILE")"
  log "Stage 07 complete — total=$total rewritten=$synced failed=$failed"

  if [[ "$DRY_RUN" -eq 0 ]]; then
    commit_state "mirror: state after stage 07 (rewrite-cross-references) [skip ci]"
  fi
}

# ---------------------------------------------------------------------------
# build_number_maps — returns JSON:
#   { "repo": { "issues": {"src_n": tgt_n, ...}, "prs": {"src_n": tgt_n, ...} } }
# issues:  source_number    → target_number
# prs:     source_pr_number → target_issue_number  (PRs become issues in target)
build_number_maps() {
  local result="{}"

  for sf in "$REPO_ROOT/state/issues/"*.yaml; do
    [[ -f "$sf" ]] || continue
    local repo
    repo="$(basename "$sf" .yaml)"
    local imap
    imap="$(jq '[.items[] |
        select(.status == "mirrored" and .target_number != null) |
        {key: (.source_number | tostring), value: .target_number}
      ] | from_entries' "$sf" 2>/dev/null || echo '{}')"
    result="$(echo "$result" | jq --arg r "$repo" --argjson m "$imap" '.[$r].issues = $m')"
  done

  for sf in "$REPO_ROOT/state/prs/"*.yaml; do
    [[ -f "$sf" ]] || continue
    local repo
    repo="$(basename "$sf" .yaml)"
    local pmap
    pmap="$(jq '[.items[] |
        select(.status == "mirrored" and .target_issue_number != null) |
        {key: (.source_pr_number | tostring), value: .target_issue_number}
      ] | from_entries' "$sf" 2>/dev/null || echo '{}')"
    result="$(echo "$result" | jq --arg r "$repo" --argjson m "$pmap" '.[$r].prs = $m')"
  done

  echo "$result"
}

# ---------------------------------------------------------------------------
# _rewrite_repo_items — rewrite bodies and comments for all mirrored items
# in one repo.  kind = "issues" | "prs"
_rewrite_repo_items() {
  local repo_name="$1"
  local kind="$2"
  local state_file="$3"

  log "  [$kind] $repo_name..."

  # Build list of {src, tgt} pairs
  local mirrored
  if [[ "$kind" == "issues" ]]; then
    mirrored="$(jq -c '[.items[] |
        select(.status == "mirrored" and .target_number != null) |
        {src: .source_number, tgt: .target_number}
      ]' "$state_file" 2>/dev/null || echo '[]')"
  else
    mirrored="$(jq -c '[.items[] |
        select(.status == "mirrored" and .target_issue_number != null) |
        {src: .source_pr_number, tgt: .target_issue_number}
      ]' "$state_file" 2>/dev/null || echo '[]')"
  fi

  local count
  count="$(echo "$mirrored" | jq 'length')"
  if [[ "$count" -eq 0 ]]; then
    log "    No mirrored items — skipping"
    return 0
  fi
  log "    $count items to process"

  local done_count=0 rewritten_count=0 nochange_count=0 failed_count=0

  while IFS= read -r item; do
    local tgt_num
    tgt_num="$(echo "$item" | jq -r '.tgt')"

    # ---- Idempotency: skip body rewrite if already done; always recheck comments.
    # Comments are NOT skipped for already-processed issues because stages 05/06
    # may have added new comments with source-org URLs after the last stage 07 run.
    # _rewrite_item_comments has its own fast-path (grep for SOURCE_ORG) so clean
    # comments are skipped with no API write.
    local already
    already="$(jq -r --arg r "$repo_name" --argjson n "$tgt_num" \
      '[.items[] | select(.repo == $r and .target_number == $n)] |
       first // {} | .status // empty' \
      "$STATE_FILE" 2>/dev/null | head -1 || true)"

    if [[ "$already" == "rewritten" || "$already" == "no_change" ]]; then
      _rewrite_item_comments "$repo_name" "$tgt_num"
      done_count=$((done_count + 1))
      continue
    fi

    # ---- Fetch and rewrite issue body --------------------------------------
    local current_body
    current_body="$(gh api "repos/$TARGET_ORG/$repo_name/issues/$tgt_num" \
      2>/dev/null | jq -rs '.[0].body // ""' 2>/dev/null || echo '')"

    local new_body
    new_body="$(echo "$current_body" | \
      python3 "$REWRITE_PY" "$SOURCE_ORG" "$TARGET_ORG" "$repo_name" "$MAPS_FILE" \
      2>/dev/null || echo "$current_body")"

    local body_status="no_change"

    if [[ "$new_body" != "$current_body" ]]; then
      if dry_run_skip "rewrite body of $TARGET_ORG/$repo_name#$tgt_num"; then
        body_status="rewritten"
        rewritten_count=$((rewritten_count + 1))
      else
        local patch_result
        patch_result="$(gh api "repos/$TARGET_ORG/$repo_name/issues/$tgt_num" \
          --method PATCH \
          --input <(printf '%s' "$new_body" | jq -Rs '{"body":.}') \
          2>/dev/null)" || patch_result="FAILED"
        if [[ "$patch_result" == "FAILED" ]]; then
          warn "    Failed to patch body of $TARGET_ORG/$repo_name#$tgt_num"
          _upsert_rewrite_record "$repo_name" "$tgt_num" "failed"
          failed_count=$((failed_count + 1))
          continue
        fi
        ok "    Rewrote $TARGET_ORG/$repo_name#$tgt_num"
        body_status="rewritten"
        rewritten_count=$((rewritten_count + 1))
      fi
    else
      nochange_count=$((nochange_count + 1))
    fi

    _upsert_rewrite_record "$repo_name" "$tgt_num" "$body_status"

    # ---- Rewrite comments on this issue ------------------------------------
    _rewrite_item_comments "$repo_name" "$tgt_num"

    done_count=$((done_count + 1))
    pause 0.3

  done < <(echo "$mirrored" | jq -c '.[]')

  log "    Done: rewritten=$rewritten_count no_change=$nochange_count failed=$failed_count"
}

# ---------------------------------------------------------------------------
# _rewrite_item_comments — fetch all comments on a target issue and rewrite
# any that still contain source-org URLs.
_rewrite_item_comments() {
  local repo_name="$1"
  local tgt_issue_num="$2"

  local comments
  comments="$(gh api \
    "repos/$TARGET_ORG/$repo_name/issues/$tgt_issue_num/comments?per_page=100" \
    --paginate 2>/dev/null | \
    jq -rs '[.[] | select(type == "object")]')" || comments='[]'

  local count
  count="$(echo "$comments" | jq -r 'if type=="array" then length else 0 end' 2>/dev/null || echo 0)"
  [[ "$count" -eq 0 ]] && return 0

  while IFS= read -r comment; do
    local c_id c_body
    c_id="$(echo   "$comment" | jq -r '.id')"
    c_body="$(echo "$comment" | jq -r '.body // ""')"

    # Fast path: skip comments with neither source-org references nor @mentions
    if ! echo "$c_body" | grep -qF "$SOURCE_ORG" 2>/dev/null && \
       ! echo "$c_body" | grep -qE '@[a-zA-Z0-9]' 2>/dev/null; then
      continue
    fi

    local new_body
    new_body="$(echo "$c_body" | \
      python3 "$REWRITE_PY" "$SOURCE_ORG" "$TARGET_ORG" "$repo_name" "$MAPS_FILE" \
      2>/dev/null || echo "$c_body")"

    if [[ "$new_body" == "$c_body" ]]; then
      continue
    fi

    if dry_run_skip "rewrite comment $c_id on $TARGET_ORG/$repo_name#$tgt_issue_num"; then
      continue
    fi

    local patch_result
    patch_result="$(gh api \
      "repos/$TARGET_ORG/$repo_name/issues/comments/$c_id" \
      --method PATCH \
      --input <(printf '%s' "$new_body" | jq -Rs '{"body":.}') \
      2>/dev/null)" || patch_result="FAILED"

    if [[ "$patch_result" == "FAILED" ]]; then
      warn "    Failed to patch comment $c_id on #$tgt_issue_num"
    else
      ok "    Rewrote comment $c_id on #$tgt_issue_num"
    fi
    pause 0.2

  done < <(echo "$comments" | jq -c '.[]')
}

# ---------------------------------------------------------------------------
_upsert_rewrite_record() {
  local repo_name="$1"
  local tgt_num="$2"
  local status="$3"
  local ts
  ts="$(now)"

  local record
  record="$(jq -n \
    --arg  repo   "$repo_name" \
    --argjson n   "$tgt_num" \
    --arg  status "$status" \
    --arg  ts     "$ts" \
    '{"repo":$repo,"target_number":$n,"status":$status,"rewritten_at":$ts}')"

  local tmp
  tmp="$(mktemp)"
  jq --arg r "$repo_name" --argjson n "$tgt_num" --argjson rec "$record" \
    'if (.items | map(select(.repo == $r and .target_number == $n)) | length) > 0
     then .items = [.items[] |
            if (.repo == $r and .target_number == $n) then $rec else . end]
     else .items += [$rec]
     end' "$STATE_FILE" > "$tmp"
  mv "$tmp" "$STATE_FILE"
}

# ---------------------------------------------------------------------------
# _write_rewrite_script — write the Python body-rewriting helper to $1.
# Called once per run; the script is reused for every body/comment.
_write_rewrite_script() {
  local path="$1"
  cat > "$path" << 'PYEOF'
#!/usr/bin/env python3
"""
Rewrite source-org GitHub links in a Markdown body.
Usage: echo BODY | python3 script.py SRC_ORG TGT_ORG REPO_NAME MAPS_FILE

MAPS_FILE contains JSON:
  { "repo": { "issues": {"src_n": tgt_n}, "prs": {"src_n": tgt_n} } }

Numbers in the JSON are integers; keys are strings (JSON object keys).
"""
import re, sys, json

def load_maps(maps_file):
    with open(maps_file) as f:
        return json.load(f)

def get_target(number_maps, repo, src_num_str, kind):
    """Return target number as string, or None if not in map."""
    v = number_maps.get(repo, {}).get(kind, {}).get(src_num_str)
    return str(v) if v is not None else None

def rewrite_body(body, src_org, tgt_org, repo_name, number_maps):
    lines = body.split('\n')
    in_code_block = False
    result = []
    for line in lines:
        stripped = line.strip()

        # Track fenced code blocks — never rewrite inside them
        if stripped.startswith('```') or stripped.startswith('~~~'):
            in_code_block = not in_code_block
            result.append(line)
            continue
        if in_code_block:
            result.append(line)
            continue

        # Protect attribution / idempotency-marker lines — never rewrite these
        if ('<!-- cf-mirror' in line
                or '**Mirrored from**' in line
                or '**Mirrored PR**' in line
                or '> 🔗' in line
                or '> Originally opened by' in line
                or '> **Author:**' in line):
            result.append(line)
            continue

        result.append(_rewrite_line(line, src_org, tgt_org, repo_name, number_maps))
    return '\n'.join(result)


def _rewrite_line(line, src_org, tgt_org, repo_name, number_maps):
    src_esc = re.escape(src_org)

    # 1. Issue URLs:  github.com/SRC/REPO/issues/N  →  github.com/TGT/REPO/issues/M
    def _issue_url(m):
        repo, n = m.group(1), m.group(2)
        tgt_n = get_target(number_maps, repo, n, 'issues') or n
        return f'https://github.com/{tgt_org}/{repo}/issues/{tgt_n}'
    line = re.sub(
        rf'https://github\.com/{src_esc}/([^/\s"\'<>]+)/issues/(\d+)',
        _issue_url, line)

    # 2. PR URLs:  github.com/SRC/REPO/pull/N  →  github.com/TGT/REPO/issues/M
    #    (PRs are mirrored as issues in the target — /pull/ becomes /issues/)
    def _pr_url(m):
        repo, n = m.group(1), m.group(2)
        tgt_n = get_target(number_maps, repo, n, 'prs') or n
        return f'https://github.com/{tgt_org}/{repo}/issues/{tgt_n}'
    line = re.sub(
        rf'https://github\.com/{src_esc}/([^/\s"\'<>]+)/pull/(\d+)',
        _pr_url, line)

    # 3. Commit URLs: SHA is the same in both orgs — only replace org name
    line = re.sub(
        rf'https://github\.com/{src_esc}/([^/\s"\'<>]+)/commit/([0-9a-fA-F]{{7,40}})',
        rf'https://github.com/{tgt_org}/\1/commit/\2',
        line)

    # 4. Any remaining source-org GitHub URL (repo root, tree, blob, raw, etc.)
    line = re.sub(
        rf'https://github\.com/{src_esc}/',
        f'https://github.com/{tgt_org}/',
        line)

    # 5. Cross-repo mentions:  SRC_ORG/REPO#N  →  TGT_ORG/REPO#M
    def _cross_mention(m):
        repo, n = m.group(1), m.group(2)
        tgt_n = (get_target(number_maps, repo, n, 'issues')
                 or get_target(number_maps, repo, n, 'prs')
                 or n)
        return f'{tgt_org}/{repo}#{tgt_n}'
    line = re.sub(
        rf'(?<![/\w]){src_esc}/([^/\s#"\'<>]+)#(\d+)',
        _cross_mention, line)

    # 6. Bare same-repo #N references  →  #M
    #    Pattern: #N not immediately preceded by /, word char, or another #
    #    (guards against URLs, hex colours, Markdown heading ##, etc.)
    #    Also handles #N at the start of the line.
    combined = {
        **number_maps.get(repo_name, {}).get('issues', {}),
        **number_maps.get(repo_name, {}).get('prs',    {}),
    }
    if combined:
        def _bare_ref(m):
            prefix = m.group(1)   # the leading char (or empty at BOL)
            n      = m.group(2)
            return prefix + '#' + str(combined.get(n, n))
        line = re.sub(
            r'(^|(?<=[^/\w#]))#(\d+)(?!\w)',
            _bare_ref, line)

    # 7. Encode @mentions as HTML entity to suppress GitHub notification emails.
    #    Split on inline code spans to preserve code formatting.
    def _encode_mentions(s):
        parts = re.split(r'(`[^`\n]*`)', s)
        out = []
        for p in parts:
            if p.startswith('`'):
                out.append(p)
            else:
                out.append(re.sub(r'@([a-zA-Z0-9][-a-zA-Z0-9]*)', r'&#64;\1', p))
        return ''.join(out)
    line = _encode_mentions(line)

    return line


if __name__ == '__main__':
    src_org   = sys.argv[1]
    tgt_org   = sys.argv[2]
    repo_name = sys.argv[3]
    maps_file = sys.argv[4]
    number_maps = load_maps(maps_file)
    body = sys.stdin.read()
    # Write without adding a trailing newline — preserve exact original length
    sys.stdout.write(rewrite_body(body, src_org, tgt_org, repo_name, number_maps))
PYEOF
}

main "$@"
