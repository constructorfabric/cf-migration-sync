#!/usr/bin/env bash
# mirror/tools/set-sub-issues.sh
# Restore parent/child (sub-issue) relationships that the main import could not
# set during issue creation, because the parent must exist before the child can
# be attached, and the mapping of source → target numbers is needed.
#
# How it works:
#   1. Reads every mirrored issue from state/issues/<repo>.yaml
#   2. For issues with a parent_issue_url in source_data, extracts the source
#      parent number and resolves it to the target parent number via the state file
#   3. Calls POST /repos/{TARGET_ORG}/{repo}/issues/{parent_number}/sub_issues
#      with { "sub_issue_id": <child_target_database_id> }
#   4. Records success/failure; safe to re-run (idempotent — duplicate attachment
#      is rejected by GitHub with 422 and treated as already-done)
#
# Requires: GH_TOKEN (target write scope), TARGET_ORG
# Usage:
#   TARGET_ORG=constructorfabric GH_TOKEN=xxx \
#     ./mirror/tools/set-sub-issues.sh [--dry-run] [--repo REPO]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

TARGET_ORG="${TARGET_ORG:-}"   # required; validated in preflight
ISSUES_STATE_DIR="$REPO_ROOT/state/issues"
MIRROR_MODE="${MIRROR_MODE:-import}"  # only writes to target

main() {
  check_dry_run "$@"
  preflight

  local only_repo=""
  for arg in "$@"; do
    [[ "$arg" == "--repo" ]] && { shift; only_repo="$1"; shift; continue; }
    [[ "$arg" == --repo=* ]] && { only_repo="${arg#--repo=}"; continue; }
  done

  log "set-sub-issues — restoring parent/child relationships"
  [[ -n "$only_repo" ]] && log "  Single-repo mode: $only_repo"

  local total_set=0 total_already=0 total_failed=0 total_skipped=0

  while IFS= read -r repo_name; do
    [[ -z "$repo_name" ]] && continue
    [[ -n "$only_repo" && "$repo_name" != "$only_repo" ]] && continue

    local state_file="$ISSUES_STATE_DIR/$repo_name.yaml"
    state_unsplit "$state_file"
    [[ -f "$state_file" ]] || continue

    # Find mirrored issues that have a parent_issue_url in their source_data.
    local parent_items
    parent_items="$(jq -c '
      [.items[] |
        select(
          .status == "mirrored" and
          .target_number != null and
          (.source_data.parent_issue_url // "") != ""
        ) |
        {
          child_src:    .source_number,
          child_tgt:    .target_number,
          parent_url:   .source_data.parent_issue_url
        }
      ]' "$state_file" 2>/dev/null || echo '[]')"

    local count
    count="$(echo "$parent_items" | jq 'length')"
    [[ "$count" -eq 0 ]] && continue

    log "  $repo_name: $count issue(s) with parent relationships"

    while IFS= read -r item; do
      [[ -z "$item" ]] && continue
      local child_src child_tgt parent_url parent_src_num
      child_src="$(echo "$item" | jq -r '.child_src')"
      child_tgt="$(echo "$item" | jq -r '.child_tgt')"
      parent_url="$(echo "$item" | jq -r '.parent_url')"

      # Extract source parent issue number from the URL.
      # URL format: https://api.github.com/repos/ORG/REPO/issues/NUMBER
      parent_src_num="$(echo "$parent_url" | grep -oE '[0-9]+$' || true)"
      if [[ -z "$parent_src_num" ]]; then
        warn "  $repo_name #$child_src: cannot parse parent number from '$parent_url'"
        total_failed=$((total_failed + 1))
        continue
      fi

      # Resolve source parent number → target parent number via state.
      local parent_tgt
      parent_tgt="$(jq -r --argjson n "$parent_src_num" \
        '.items[] | select(.source_number == $n) | .target_number // empty' \
        "$state_file" 2>/dev/null | head -1 || true)"

      if [[ -z "$parent_tgt" || "$parent_tgt" == "null" ]]; then
        warn "  $repo_name #$child_src: parent source #$parent_src_num not yet mirrored — skipping (retry after parent is imported)"
        total_skipped=$((total_skipped + 1))
        continue
      fi

      if dry_run_skip "attach $repo_name #$child_tgt as sub-issue of #$parent_tgt (source: #$child_src under #$parent_src_num)"; then
        total_set=$((total_set + 1))
        continue
      fi

      # The sub-issues API needs the child's TARGET DATABASE ID (not number).
      # Fetch the child issue to get its numeric id.
      local child_issue_json child_db_id
      child_issue_json="$(gh api "repos/$TARGET_ORG/$repo_name/issues/$child_tgt" 2>/dev/null)" || child_issue_json=""
      child_db_id="$(printf '%s' "$child_issue_json" | jq -r '.id // empty' 2>/dev/null || true)"

      if [[ -z "$child_db_id" || "$child_db_id" == "null" ]]; then
        warn "  $repo_name: could not get database id for target issue #$child_tgt — skipping"
        total_failed=$((total_failed + 1))
        continue
      fi

      # POST to the PARENT issue to add the CHILD as a sub-issue.
      local result
      result="$(gh api "repos/$TARGET_ORG/$repo_name/issues/$parent_tgt/sub_issues" \
        --method POST \
        -F sub_issue_id="$child_db_id" \
        2>/dev/null)" || result="FAILED"

      if [[ "$result" == "FAILED" ]]; then
        # 422 = already attached; treat as success.
        # Refetch to check if it is actually attached already.
        local check
        check="$(gh api "repos/$TARGET_ORG/$repo_name/issues/$child_tgt" 2>/dev/null | jq -r '.parent_issue_url // empty' 2>/dev/null || true)"
        if [[ -n "$check" ]]; then
          log "  $repo_name #$child_tgt already sub-issue of #$parent_tgt"
          total_already=$((total_already + 1))
        else
          warn "  $repo_name #$child_tgt: failed to attach as sub-issue of #$parent_tgt"
          total_failed=$((total_failed + 1))
        fi
      else
        ok "  $repo_name #$child_tgt (src #$child_src) → sub-issue of #$parent_tgt (src #$parent_src_num)"
        total_set=$((total_set + 1))
      fi

      pause 0.5   # small gap between API calls; no heavy throttle needed (reads + one write each)

    done < <(echo "$parent_items" | jq -c '.[]')

    state_split_if_needed "$state_file"

  done < <(state_repo_names "$ISSUES_STATE_DIR")

  log "set-sub-issues complete — set=$total_set already=$total_already skipped=$total_skipped failed=$total_failed"
}

main "$@"
