#!/usr/bin/env bash
# 05-migrate-issues.sh — migrate issues (with comments) from source repos to target
#
# Usage:
#   ./05-migrate-issues.sh                 # migrate issues in all repos that have them
#   ./05-migrate-issues.sh <repo-name>     # migrate just one repo
#
# Behavior:
#   - Preserves issue title, body, labels, milestone, state
#   - Original author + creation date noted in body preamble
#   - Closed/open state preserved
#   - Comments are migrated with author attribution
#   - Idempotent: re-running won't create duplicates (uses HTML-comment marker)
#
# Rate-limited: ~0.5s pause between API writes. Large repos (cyberware-rust)
# take 1–2 hours. Run inside tmux/screen.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"
preflight

# Repos with issues per the inventory. Run all of these by default.
DEFAULT_REPOS=(
  cyberware-rust       # 231 open + 849 closed
  cyber-insight        # 178 open + 113 closed
  cyberware-frontx     # 38 open + 52 closed
  cyber-constructor    # 10 open + 21 closed
  cf-cli               # 7 open + 1 closed
  governance           # 4 open
  cf-template-rust     # 3 open + 1 closed
  cf-docs              # 1 open
)

migrate_one_repo() {
  local REPO="$1"
  log "Migrating issues for ${REPO}"

  # Build milestone number map (source → target by title)
  declare -A MS_MAP
  while IFS=$'\t' read -r src_num title; do
    [ -z "$src_num" ] && continue
    tgt_num=$(gh api "repos/${TARGET_ORG}/${REPO}/milestones?state=all" --paginate \
      --jq ".[] | select(.title==\"${title}\") | .number" 2>/dev/null | head -1)
    [ -n "$tgt_num" ] && MS_MAP["$src_num"]="$tgt_num"
  done < <(ghsrc api "repos/${SOURCE_ORG}/${REPO}/milestones?state=all" --paginate \
    --jq '.[] | [(.number | tostring), .title] | @tsv' 2>/dev/null)

  local TOTAL=0 CREATED=0 SKIPPED=0
  while read -r issue; do
    [ -z "$issue" ] && continue
    TOTAL=$((TOTAL + 1))

    number=$(echo "$issue" | jq -r '.number')
    title=$(echo "$issue"   | jq -r '.title')
    body=$(echo "$issue"    | jq -r '.body // ""')
    state=$(echo "$issue"   | jq -r '.state')
    author=$(echo "$issue"  | jq -r '.user.login')
    created=$(echo "$issue" | jq -r '.created_at')
    labels=$(echo "$issue"  | jq -r '[.labels[].name]')
    assignees=$(echo "$issue" | jq -r '[.assignees[].login]')
    src_ms=$(echo "$issue"  | jq -r '.milestone.number // empty')

    MARKER="<!-- cf-mirror: ${SOURCE_ORG}/${REPO}#${number} -->"

    # Idempotency: skip if already migrated
    EXISTING=$(gh api "repos/${TARGET_ORG}/${REPO}/issues?state=all&per_page=100" \
      --paginate \
      --jq ".[] | select(.body != null and (.body | contains(\"cf-mirror: ${SOURCE_ORG}/${REPO}#${number} -->\"))) | .number" \
      2>/dev/null | head -1)
    if [ -n "$EXISTING" ]; then
      SKIPPED=$((SKIPPED + 1))
      continue
    fi

    new_body="${MARKER}
> 📌 Originally by @${author} on ${created}

${body}"

    PAYLOAD=$(jq -n \
      --arg title "$title" \
      --arg body "$new_body" \
      --argjson labels "$labels" \
      --argjson assignees "$assignees" \
      '{title:$title,body:$body,labels:$labels,assignees:$assignees}')

    # Add milestone if mapped
    if [ -n "$src_ms" ] && [ -n "${MS_MAP[$src_ms]+x}" ]; then
      PAYLOAD=$(echo "$PAYLOAD" | jq --argjson ms "${MS_MAP[$src_ms]}" '.+{milestone:$ms}')
    fi

    NEW=$(gh api "repos/${TARGET_ORG}/${REPO}/issues" \
      -X POST --input - <<< "$PAYLOAD" 2>/dev/null)
    NEW_NUMBER=$(echo "$NEW" | jq -r '.number // empty')
    if [ -z "$NEW_NUMBER" ]; then
      err "Failed to create issue #${number}"
      continue
    fi

    # Migrate comments
    while read -r comment; do
      [ -z "$comment" ] && continue
      c_author=$(echo "$comment"  | jq -r '.user.login')
      c_created=$(echo "$comment" | jq -r '.created_at')
      c_body=$(echo "$comment"    | jq -r '.body')
      gh api "repos/${TARGET_ORG}/${REPO}/issues/${NEW_NUMBER}/comments" \
        -X POST -f body="> 💬 Originally by @${c_author} on ${c_created}

${c_body}" >/dev/null 2>&1 || true
      pause 0.2
    done < <(ghsrc api "repos/${SOURCE_ORG}/${REPO}/issues/${number}/comments" \
      --paginate --jq '.[]' 2>/dev/null)

    # Close if closed in source
    if [ "$state" = "closed" ]; then
      gh api "repos/${TARGET_ORG}/${REPO}/issues/${NEW_NUMBER}" \
        -X PATCH -f state="closed" >/dev/null 2>&1 || true
    fi

    CREATED=$((CREATED + 1))
    [ $((CREATED % 25)) -eq 0 ] && echo "  ...migrated ${CREATED} issues so far in ${REPO}"
    pause 0.5
  done < <(ghsrc api "repos/${SOURCE_ORG}/${REPO}/issues?state=all&direction=asc&per_page=100" \
    --paginate --jq '.[] | select(.pull_request == null)' 2>/dev/null)

  ok "${REPO}: created=${CREATED} skipped=${SKIPPED} total=${TOTAL}"
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
