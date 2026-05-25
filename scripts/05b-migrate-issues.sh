#!/usr/bin/env bash
# 05b-migrate-issues.sh — migrate issues from YAML files (produced by 05a) to target org
#
# Usage:
#   ./05b-migrate-issues.sh                 # migrate all repos
#   ./05b-migrate-issues.sh <repo-name>     # migrate one repo
#
# Behavior:
#   - Reads issues/<repo>.yaml written by 05a-fetch-issues.sh
#   - CREATE: new issues with comments and correct closed/open state
#   - UPDATE: existing issues (title, body, state, labels, assignees) if already migrated
#   - Idempotent: uses <!-- cf-mirror: org/repo#N --> marker to detect existing issues
#   - Comments are only added on CREATE (not re-added on UPDATE to avoid duplicates)
#
# Only writes to the TARGET org — does not touch the source.
# Run inside tmux/screen for large repos.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"
preflight

INPUT_DIR="${SCRIPT_DIR}/../issues"

DEFAULT_REPOS=(
  cyberware-rust
  cyber-insight
  cyberware-frontx
  cyber-constructor
  cf-cli
  governance
  cf-template-rust
  cf-docs
)

migrate_one_repo() {
  local REPO="$1"
  local INPUT="${INPUT_DIR}/${REPO}.yaml"

  if [ ! -f "$INPUT" ]; then
    warn "No data file for ${REPO}: expected ${INPUT}"
    warn "Run ./scripts/05a-fetch-issues.sh ${REPO} first"
    return
  fi

  log "Migrating issues for ${REPO} from ${INPUT}"

  # ── Milestone map: source title → target number ───────────────────────────
  local MS_TSV
  MS_TSV=$(mktemp)
  trap "rm -f '$MS_TSV'" RETURN

  gh api "repos/${TARGET_ORG}/${REPO}/milestones?state=all" --paginate \
    --jq '.[] | [.title, (.number | tostring)] | @tsv' \
    2>/dev/null > "$MS_TSV" || true

  ms_by_title() {
    awk -F'\t' -v t="$1" '$1 == t { print $2; exit }' "$MS_TSV"
  }

  # ── Pre-load all existing target issues that have a cf-mirror marker ───────
  # Builds a TSV: <source_issue_number> <tab> <target_issue_number>
  # so we can detect already-migrated issues in O(1) without per-issue API calls.
  log "  Loading existing issues from ${TARGET_ORG}/${REPO}..."
  local EXISTING_TSV
  EXISTING_TSV=$(mktemp)
  trap "rm -f '$EXISTING_TSV'" RETURN

  # NOTE: gh api --jq does not support --arg; use inline bash variable substitution.
  # Split on the marker prefix to extract the source issue number cleanly.
  local SRC_PREFIX="cf-mirror: ${SOURCE_ORG}/${REPO}#"
  gh api "repos/${TARGET_ORG}/${REPO}/issues?state=all&per_page=100" \
    --paginate \
    --jq ".[] | select(.body != null and (.body | contains(\"${SRC_PREFIX}\")))
          | [
              (.body | split(\"${SRC_PREFIX}\")[1] | split(\" -->\")[0]),
              (.number | tostring)
            ] | @tsv" \
    2>/dev/null > "$EXISTING_TSV" || true

  existing_target_number() {
    awk -F'\t' -v n="$1" '$1 == n { print $2; exit }' "$EXISTING_TSV"
  }

  # ── Main loop ─────────────────────────────────────────────────────────────
  local TOTAL=0 CREATED=0 UPDATED=0 ERRORS=0

  while read -r issue; do
    [ -z "$issue" ] && continue
    TOTAL=$((TOTAL + 1))

    local number title body state author created labels assignees ms_title comments
    number=$(echo "$issue"    | jq -r '.number')
    title=$(echo "$issue"     | jq -r '.title')
    body=$(echo "$issue"      | jq -r '.body')
    state=$(echo "$issue"     | jq -r '.state')
    author=$(echo "$issue"    | jq -r '.author')
    created=$(echo "$issue"   | jq -r '.created_at')
    labels=$(echo "$issue"    | jq -r '.labels')
    assignees=$(echo "$issue" | jq -r '.assignees')
    ms_title=$(echo "$issue"  | jq -r '.milestone_title // empty')
    comments=$(echo "$issue"  | jq -r '.comments')

    local MARKER="<!-- cf-mirror: ${SOURCE_ORG}/${REPO}#${number} -->"

    local new_body
    new_body="${MARKER}
> 📌 Originally by @${author} on ${created}

${body}"

    # Build base payload — assignees intentionally omitted to avoid notification
    # flood during migration. Run 12-reassign.sh afterwards to re-apply them.
    local PAYLOAD
    PAYLOAD=$(jq -n \
      --arg     title  "$title" \
      --arg     body   "$new_body" \
      --argjson labels "$labels" \
      '{title: $title, body: $body, labels: $labels}')

    # Attach milestone if we can map it
    if [ -n "$ms_title" ]; then
      local tgt_ms
      tgt_ms=$(ms_by_title "$ms_title")
      if [ -n "$tgt_ms" ]; then
        PAYLOAD=$(echo "$PAYLOAD" | jq --argjson ms "$tgt_ms" '. + {milestone: ($ms | tonumber)}')
      fi
    fi

    # ── UPDATE existing issue ──────────────────────────────────────────────
    local EXISTING_NUM
    EXISTING_NUM=$(existing_target_number "$number")

    if [ -n "$EXISTING_NUM" ]; then
      echo "$PAYLOAD" | jq --arg state "$state" '. + {state: $state}' | \
        gh api "repos/${TARGET_ORG}/${REPO}/issues/${EXISTING_NUM}" \
          -X PATCH --input - >/dev/null 2>&1 || true
      UPDATED=$((UPDATED + 1))
      [ $((UPDATED % 25)) -eq 0 ] && echo "  ...updated ${UPDATED} issues so far in ${REPO}"
      pause 0.3
      continue
    fi

    # ── CREATE new issue ───────────────────────────────────────────────────
    local NEW NEW_NUMBER
    NEW=$(echo "$PAYLOAD" | gh api "repos/${TARGET_ORG}/${REPO}/issues" \
      -X POST --input - 2>/dev/null || true)
    NEW_NUMBER=$(echo "$NEW" | jq -r '.number // empty')

    # Retry helper: extract the specific invalid values for a given field from a 422 response
    bad_values_for() {
      local resp="$1" field="$2"
      echo "$resp" | jq -r --arg f "$field" '
        [.errors[]? | select(.field == $f and .code == "invalid") |
         (try (.value | fromjson) catch .value)] | flatten | .[]
      ' 2>/dev/null || true
    }

    # Retry 1: remove only the specific invalid labels GitHub identified
    if [ -z "$NEW_NUMBER" ] && \
       echo "$NEW" | jq -e '.message == "Validation Failed"' >/dev/null 2>&1; then
      bad_labels=$(bad_values_for "$NEW" "label")
      if [ -n "$bad_labels" ]; then
        warn "Issue #${number}: invalid label(s): $(echo "$bad_labels" | tr '\n' ' ') — removing and retrying"
        bad_arr=$(echo "$bad_labels" | jq -R . | jq -s .)
        PAYLOAD=$(echo "$PAYLOAD" | jq --argjson bad "$bad_arr" '.labels -= $bad')
      else
        # Non-label validation error — strip all labels as a fallback
        warn "Issue #${number}: Validation Failed — stripping labels and retrying"
        PAYLOAD=$(echo "$PAYLOAD" | jq '.labels = []')
      fi
      NEW=$(echo "$PAYLOAD" | gh api "repos/${TARGET_ORG}/${REPO}/issues" \
        -X POST --input - 2>/dev/null || true)
      NEW_NUMBER=$(echo "$NEW" | jq -r '.number // empty')
    fi

    # Retry 2: remove only the specific invalid assignees GitHub identified
    # Cause: users who have no access to the repo return code=invalid instead of being
    # silently dropped (happens when org default_repository_permission=none).
    if [ -z "$NEW_NUMBER" ] && \
       echo "$NEW" | jq -e '.message == "Validation Failed"' >/dev/null 2>&1; then
      bad_assignees=$(bad_values_for "$NEW" "assignees")
      if [ -n "$bad_assignees" ]; then
        warn "Issue #${number}: invalid assignee(s): $(echo "$bad_assignees" | tr '\n' ' ') — removing and retrying"
        bad_arr=$(echo "$bad_assignees" | jq -R . | jq -s .)
        PAYLOAD=$(echo "$PAYLOAD" | jq --argjson bad "$bad_arr" '.assignees -= $bad')
      else
        warn "Issue #${number}: Validation Failed after label fix — stripping assignees and retrying"
        PAYLOAD=$(echo "$PAYLOAD" | jq '.assignees = []')
      fi
      NEW=$(echo "$PAYLOAD" | gh api "repos/${TARGET_ORG}/${REPO}/issues" \
        -X POST --input - 2>/dev/null || true)
      NEW_NUMBER=$(echo "$NEW" | jq -r '.number // empty')
    fi

    # Retry 3: strip milestone (may not exist in target yet)
    if [ -z "$NEW_NUMBER" ] && \
       echo "$NEW" | jq -e '.message == "Validation Failed"' >/dev/null 2>&1; then
      warn "Issue #${number}: still failing — stripping milestone and retrying"
      NEW=$(echo "$PAYLOAD" | jq 'del(.milestone)' | \
        gh api "repos/${TARGET_ORG}/${REPO}/issues" \
          -X POST --input - 2>/dev/null || true)
      NEW_NUMBER=$(echo "$NEW" | jq -r '.number // empty')
    fi

    if [ -z "$NEW_NUMBER" ]; then
      err "Issue #${number}: all retries failed — $(echo "$NEW" | jq -r '.message // "unknown"')"
      echo "$NEW" | jq -r '.errors[]? | "    field=\(.field // "?") code=\(.code // "?") value=\(.value // "?")"' 2>/dev/null || true
      ERRORS=$((ERRORS + 1))
      continue
    fi

    # Migrate comments (only on create — not re-added on subsequent updates)
    echo "$comments" | jq -c '.[]?' | while read -r comment; do
      [ -z "$comment" ] && continue
      local c_author c_created c_body
      c_author=$(echo "$comment"  | jq -r '.author')
      c_created=$(echo "$comment" | jq -r '.created_at')
      c_body=$(echo "$comment"    | jq -r '.body')

      gh api "repos/${TARGET_ORG}/${REPO}/issues/${NEW_NUMBER}/comments" \
        -X POST -f body="> 💬 Originally by @${c_author} on ${c_created}

${c_body}" >/dev/null 2>&1 || true
      pause 0.2
    done

    # Close if originally closed
    if [ "$state" = "closed" ]; then
      gh api "repos/${TARGET_ORG}/${REPO}/issues/${NEW_NUMBER}" \
        -X PATCH -f state="closed" >/dev/null 2>&1 || true
    fi

    CREATED=$((CREATED + 1))
    [ $((CREATED % 25)) -eq 0 ] && echo "  ...created ${CREATED} issues so far in ${REPO}"
    pause 0.5

  done < <(jq -c '.[]' "$INPUT")

  ok "${REPO}: created=${CREATED} updated=${UPDATED} errors=${ERRORS} total=${TOTAL}"
}

if [ $# -ge 1 ]; then
  migrate_one_repo "$1"
else
  for r in "${DEFAULT_REPOS[@]}"; do
    migrate_one_repo "$r"
    log "Pausing 10s between repos..."
    sleep 10
  done
fi

echo ""
warn "Reminder: GitHub silently drops assignees who aren't yet org members."
warn "After invitations are accepted (24h+), run ./scripts/12-reassign.sh"
warn "to re-apply assignees from source. It's safe to run multiple times."
