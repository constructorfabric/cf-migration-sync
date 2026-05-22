#!/usr/bin/env bash
# 06-migrate-prs.sh — recreate OPEN pull requests in target repos
#
# Closed/merged PRs are NOT migrated (they live in git history). See Appendix B
# of the migration guide for archiving closed PRs as issues if needed.
#
# Usage:
#   ./06-migrate-prs.sh                 # all repos with open PRs
#   ./06-migrate-prs.sh <repo-name>     # one repo
#
# Idempotent: existing mirrored PRs are detected by HTML-comment marker.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"
preflight

DEFAULT_REPOS=(
  cyberware-rust          # 46 open
  cyberware-frontx        # 13 open
  cyber-insight           # 11 open
  cyberfabric-courses     # 4 open
  cyber-arc               # 3 open
  cyber-insight-front     # 2 open
  cf-cli                  # 2 open
  cyber-constructor       # 2 open
  DNA                     # 1 open
  cf-template-rust        # 1 open
  cyberware-csharp        # 1 open
  cyber-wiki              # 1 open
  cyber-wiki-back         # 1 open
  cyber-wiki-front        # 1 open
  cyber-constructor-app   # 1 open
  demo-repository         # 1 open
)

migrate_one_repo() {
  local REPO="$1"
  log "Migrating open PRs for ${REPO}"

  local CREATED=0 SKIPPED=0 MISSING_BRANCH=0
  while read -r pr; do
    [ -z "$pr" ] && continue
    number=$(echo "$pr" | jq -r '.number')
    title=$(echo "$pr"  | jq -r '.title')
    body=$(echo "$pr"   | jq -r '.body // ""')
    head=$(echo "$pr"   | jq -r '.head.ref')
    base=$(echo "$pr"   | jq -r '.base.ref')
    author=$(echo "$pr" | jq -r '.user.login')
    created=$(echo "$pr"| jq -r '.created_at')
    draft=$(echo "$pr"  | jq -r '.draft')
    labels=$(echo "$pr" | jq -r '[.labels[].name]')

    MARKER="<!-- cf-mirror: ${SOURCE_ORG}/${REPO}#PR${number} -->"

    # Idempotency check
    EXISTING=$(gh api "repos/${TARGET_ORG}/${REPO}/pulls?state=open&per_page=100" \
      --paginate \
      --jq ".[] | select(.body != null and (.body | contains(\"cf-mirror: ${SOURCE_ORG}/${REPO}#PR${number} -->\"))) | .number" \
      2>/dev/null | head -1)
    if [ -n "$EXISTING" ]; then
      SKIPPED=$((SKIPPED + 1))
      continue
    fi

    # Branch must exist in target (it should after Phase 1 mirror)
    if ! gh api "repos/${TARGET_ORG}/${REPO}/branches/${head}" --jq '.name' >/dev/null 2>&1; then
      warn "PR #${number}: head branch '${head}' not in target — skipping"
      MISSING_BRANCH=$((MISSING_BRANCH + 1))
      continue
    fi

    new_body="${MARKER}
> 📌 Originally by @${author} on ${created} (was PR #${number} in ${SOURCE_ORG})

${body}"

    PAYLOAD=$(jq -n \
      --arg title "$title" --arg body "$new_body" \
      --arg head "$head" --arg base "$base" \
      --argjson draft "$draft" \
      '{title:$title,body:$body,head:$head,base:$base,draft:$draft}')

    NEW=$(gh api "repos/${TARGET_ORG}/${REPO}/pulls" \
      -X POST --input - <<< "$PAYLOAD" 2>/dev/null)
    NEW_NUMBER=$(echo "$NEW" | jq -r '.number // empty')
    if [ -z "$NEW_NUMBER" ]; then
      err "Failed to create PR #${number}"
      continue
    fi

    # Apply labels
    if [ "$labels" != "[]" ]; then
      gh api "repos/${TARGET_ORG}/${REPO}/issues/${NEW_NUMBER}/labels" \
        -X POST --input - <<< "{\"labels\":${labels}}" >/dev/null 2>&1 || true
    fi

    CREATED=$((CREATED + 1))
    echo "  PR #${number} → #${NEW_NUMBER}: ${title}"
    pause 0.5
  done < <(gh api "repos/${SOURCE_ORG}/${REPO}/pulls?state=open&direction=asc&per_page=100" \
    --paginate --jq '.[]' 2>/dev/null)

  ok "${REPO}: created=${CREATED} skipped=${SKIPPED} missing_branch=${MISSING_BRANCH}"
}

if [ $# -ge 1 ]; then
  migrate_one_repo "$1"
else
  for r in "${DEFAULT_REPOS[@]}"; do
    migrate_one_repo "$r"
    sleep 5
  done
fi
