#!/usr/bin/env bash
# mirror/stages/16-set-sub-issues.sh
# Restore parent/child (sub-issue) relationships after all issues have been
# imported. The parent must already exist in the target before its children
# can be attached — so this is a separate pass, not part of stage 05.
#
# The parent_issue_url is captured in source_data.parent_issue_url during
# export (stage 05); the source→target number mapping comes from the same
# state files. No re-export needed.
#
# Modes (MIRROR_MODE):
#   full   — same as import: set relationships against the target.
#   export — NO-OP. parent_issue_url is already captured in source_data by
#            stage 05 export; nothing to do here.
#   import — read state files, resolve source→target mappings, attach
#            sub-issues. Idempotent: already-attached is silently skipped.
#
# State file: none (relationships are sourced from state/issues/<repo>.yaml).
# Idempotency: GitHub returns 422 if already attached; treated as success.
#
# Usage:
#   TARGET_ORG=constructorfabric GH_TOKEN=xxx \
#   MIRROR_MODE=import \
#   ./mirror/stages/16-set-sub-issues.sh [--dry-run] [--repo REPO]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

TARGET_ORG="${TARGET_ORG:-}"
ISSUES_STATE_DIR="$REPO_ROOT/state/issues"

# ---------------------------------------------------------------------------
main() {
  local only_repo=""
  local passthrough_args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) only_repo="$2"; shift 2 ;;
      *)      passthrough_args+=("$1"); shift ;;
    esac
  done

  check_dry_run "${passthrough_args[@]+"${passthrough_args[@]}"}"
  preflight

  log "Stage 16 — set-sub-issues starting (mode=$MIRROR_MODE)"

  if in_export; then
    log "Stage 16 is target-side only — nothing to export. (parent_issue_url captured by stage 05.) Skipping."
    return 0
  fi

  if ! writes_target; then
    warn "Stage 16: nothing to do in mode=$MIRROR_MODE"
    return 0
  fi

  [[ -n "$only_repo" ]] && log "  Single-repo mode: $only_repo"

  local total_set=0 total_already=0 total_failed=0 total_skipped=0

  while IFS= read -r repo_name; do
    [[ -z "$repo_name" ]] && continue
    [[ -n "$only_repo" && "$repo_name" != "$only_repo" ]] && continue

    local state_file="$ISSUES_STATE_DIR/$repo_name.yaml"
    state_unsplit "$state_file"
    [[ -f "$state_file" ]] || continue

    # Issues with a parent_issue_url and a resolved target number.
    local parent_items
    parent_items="$(jq -c '
      [.items[] |
        select(
          .status == "mirrored" and
          .target_number != null and
          (.source_data.parent_issue_url // "") != ""
        ) |
        {
          child_src:  .source_number,
          child_tgt:  .target_number,
          parent_url: .source_data.parent_issue_url
        }
      ]' "$state_file" 2>/dev/null || echo '[]')"

    local count
    count="$(echo "$parent_items" | jq 'length')"
    [[ "$count" -eq 0 ]] && { state_split_if_needed "$state_file"; continue; }

    log "  $repo_name: $count issue(s) with parent relationships to restore"

    while IFS= read -r item; do
      [[ -z "$item" ]] && continue
      local child_src child_tgt parent_url parent_src_num
      child_src="$(echo "$item" | jq -r '.child_src')"
      child_tgt="$(echo "$item" | jq -r '.child_tgt')"
      parent_url="$(echo "$item" | jq -r '.parent_url')"

      # Extract source parent number from URL (ends in /issues/NUMBER).
      parent_src_num="$(echo "$parent_url" | grep -oE '[0-9]+$' || true)"
      if [[ -z "$parent_src_num" ]]; then
        warn "  $repo_name #$child_src: cannot parse parent number from '$parent_url'"
        total_failed=$((total_failed + 1))
        continue
      fi

      # Look up target parent number in state.
      local parent_tgt
      parent_tgt="$(jq -r --argjson n "$parent_src_num" \
        '.items[] | select(.source_number == $n) | .target_number // empty' \
        "$state_file" 2>/dev/null | head -1 || true)"

      if [[ -z "$parent_tgt" || "$parent_tgt" == "null" ]]; then
        warn "  $repo_name #$child_src: parent source #$parent_src_num not yet mirrored — skipping (re-run after parent is imported)"
        total_skipped=$((total_skipped + 1))
        continue
      fi

      if dry_run_skip "attach $repo_name #$child_tgt as sub-issue of #$parent_tgt (src: #$child_src → #$parent_src_num)"; then
        total_set=$((total_set + 1))
        continue
      fi

      # sub-issues API requires the child's DATABASE ID (integer .id, not .number).
      # Fetch the target child issue to get its id.
      local child_json child_db_id
      child_json="$(gh api "repos/$TARGET_ORG/$repo_name/issues/$child_tgt" 2>/dev/null)" || child_json=""
      child_db_id="$(printf '%s' "$child_json" | jq -r '.id // empty' 2>/dev/null || true)"

      if [[ -z "$child_db_id" || "$child_db_id" == "null" ]]; then
        warn "  $repo_name: could not get database id for target issue #$child_tgt — skipping"
        total_failed=$((total_failed + 1))
        continue
      fi

      # Attach the child as a sub-issue of the parent.
      local result
      result="$(gh api "repos/$TARGET_ORG/$repo_name/issues/$parent_tgt/sub_issues" \
        --method POST \
        -F sub_issue_id="$child_db_id" \
        2>/dev/null)" || result="FAILED"

      if [[ "$result" == "FAILED" ]]; then
        # 422 most likely means already attached. Verify by checking the child's parent.
        local check
        check="$(gh api "repos/$TARGET_ORG/$repo_name/issues/$child_tgt" 2>/dev/null \
          | jq -r '.parent_issue_url // empty' 2>/dev/null || true)"
        if [[ -n "$check" ]]; then
          log "  $repo_name #$child_tgt already sub-issue of #$parent_tgt — skipping"
          total_already=$((total_already + 1))
        else
          warn "  $repo_name #$child_tgt: failed to attach as sub-issue of #$parent_tgt"
          total_failed=$((total_failed + 1))
        fi
      else
        ok "  $repo_name #$child_tgt (src #$child_src) → sub-issue of #$parent_tgt (src #$parent_src_num)"
        total_set=$((total_set + 1))
      fi

      pause 0.5

    done < <(echo "$parent_items" | jq -c '.[]')

    state_split_if_needed "$state_file"

  done < <(state_repo_names "$ISSUES_STATE_DIR")

  log "Stage 16 complete — set=$total_set already=$total_already skipped=$total_skipped failed=$total_failed"

  if [[ "$DRY_RUN" -eq 0 ]]; then
    commit_state "mirror: state after stage 16 (set-sub-issues) [skip ci]"
  fi
}

main "$@"
