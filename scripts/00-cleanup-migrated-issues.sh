#!/usr/bin/env bash
# 00-cleanup-migrated-issues.sh — permanently delete all issues created by the migration
#
# Finds every issue whose body contains a <!-- cf-mirror: ... --> marker and
# deletes it via the GraphQL API (requires org owner / admin token).
#
# Usage:
#   ./00-cleanup-migrated-issues.sh               # all repos
#   ./00-cleanup-migrated-issues.sh <repo-name>   # one repo
#
# Runs a dry-run preview first and asks for confirmation before deleting.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"
preflight

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

delete_one_repo() {
  local REPO="$1"
  log "Scanning ${TARGET_ORG}/${REPO} for migrated issues..."

  # Collect all issues that carry a cf-mirror marker
  local ISSUES
  ISSUES=$(gh api "repos/${TARGET_ORG}/${REPO}/issues?state=all&per_page=100" \
    --paginate \
    --jq '.[] | select(.body != null and (.body | contains("<!-- cf-mirror:")))
          | {number: .number, node_id: .node_id, title: .title}' \
    2>/dev/null || true)

  local count
  count=$(echo "$ISSUES" | jq -r '.number' 2>/dev/null | grep -c . || true)

  if [ "$count" -eq 0 ]; then
    ok "${REPO}: no migrated issues found"
    return
  fi

  warn "${REPO}: found ${count} migrated issue(s) to delete:"
  echo "$ISSUES" | jq -r '"  #\(.number) \(.title)"' 2>/dev/null | head -20
  [ "$count" -gt 20 ] && echo "  ... and $((count - 20)) more"

  echo ""
  if ! confirm "Delete all ${count} issues in ${TARGET_ORG}/${REPO}?"; then
    log "Skipped ${REPO}"
    return
  fi

  local deleted=0 failed=0
  while read -r issue; do
    [ -z "$issue" ] && continue
    local node_id number title
    node_id=$(echo "$issue" | jq -r '.node_id')
    number=$(echo "$issue"  | jq -r '.number')
    title=$(echo "$issue"   | jq -r '.title')

    if gh api graphql \
         -f query='mutation($id:ID!){deleteIssue(input:{issueId:$id}){repository{name}}}' \
         -f id="$node_id" >/dev/null 2>&1; then
      echo "  deleted #${number}: ${title}"
      deleted=$((deleted + 1))
    else
      err "  failed to delete #${number}: ${title}"
      failed=$((failed + 1))
    fi
    pause 0.3
  done < <(echo "$ISSUES" | jq -c '.' 2>/dev/null)

  ok "${REPO}: deleted=${deleted} failed=${failed} total=${count}"
}

if [ $# -ge 1 ]; then
  delete_one_repo "$1"
else
  warn "This will delete ALL migrated issues from ALL repos in ${TARGET_ORG}."
  confirm "Continue?" || { log "Aborted."; exit 0; }
  for r in "${DEFAULT_REPOS[@]}"; do
    delete_one_repo "$r"
    echo ""
  done
fi

log "Done. Re-run 05b-migrate-issues.sh to migrate cleanly."
