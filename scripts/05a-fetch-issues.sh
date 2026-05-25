#!/usr/bin/env bash
# 05a-fetch-issues.sh — fetch all issues + comments from source repos into YAML files
#
# Output: issues/<repo>.yaml  (one file per repo, JSON array — JSON is valid YAML)
#
# Usage:
#   ./05a-fetch-issues.sh                 # fetch all repos
#   ./05a-fetch-issues.sh <repo-name>     # fetch one repo
#
# Only reads from the SOURCE org (uses GH_TOKEN_SOURCE if set).
# Safe to re-run — overwrites existing YAML files.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"
preflight

OUTPUT_DIR="${SCRIPT_DIR}/../issues"
mkdir -p "$OUTPUT_DIR"

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

fetch_one_repo() {
  local REPO="$1"
  local OUT="${OUTPUT_DIR}/${REPO}.yaml"
  local JSONL
  JSONL=$(mktemp)
  trap "rm -f '$JSONL'" RETURN

  log "Fetching issues for ${REPO}..."
  local count=0

  while read -r issue; do
    [ -z "$issue" ] && continue

    local number
    number=$(echo "$issue" | jq -r '.number')

    # Fetch all comments for this issue
    local comments
    comments=$(ghsrc api "repos/${SOURCE_ORG}/${REPO}/issues/${number}/comments" \
      --paginate \
      --jq '[.[] | {author: .user.login, created_at: .created_at, body: (.body // "")}]' \
      2>/dev/null || echo "[]")

    # Combine issue + comments into one object, write as a single JSON line.
    # assignees are stored for reference / 12-reassign.sh but NOT sent during
    # issue creation (avoids notification flood — see 05b-migrate-issues.sh).
    echo "$issue" | jq -c \
      --argjson comments "$comments" \
      '{
        number:           .number,
        title:            .title,
        body:             (.body // ""),
        state:            .state,
        author:           .user.login,
        created_at:       .created_at,
        labels:           [.labels[].name],
        assignees:        [.assignees[].login],
        milestone_number: (.milestone.number // null),
        milestone_title:  (.milestone.title  // null),
        comments:         $comments
      }' >> "$JSONL"

    count=$((count + 1))
    [ $((count % 50)) -eq 0 ] && log "  ...fetched ${count} issues from ${REPO}"
    pause 0.2

  done < <(ghsrc api \
      "repos/${SOURCE_ORG}/${REPO}/issues?state=all&direction=asc&per_page=100" \
      --paginate \
      --jq '.[] | select(.pull_request == null)' \
      2>/dev/null)

  # Combine all JSONL lines into a pretty-printed JSON array
  jq -s '.' "$JSONL" > "$OUT"
  ok "${REPO}: fetched ${count} issues → ${OUT}"
}

if [ $# -ge 1 ]; then
  fetch_one_repo "$1"
else
  for r in "${DEFAULT_REPOS[@]}"; do
    fetch_one_repo "$r"
    log "Pausing 5s between repos..."
    sleep 5
  done
fi

echo ""
log "All issues saved to ${OUTPUT_DIR}/"
log "Next step: ./scripts/05b-migrate-issues.sh"
