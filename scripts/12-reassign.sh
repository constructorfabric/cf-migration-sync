#!/usr/bin/env bash
# 12-reassign.sh — re-apply original assignees to migrated issues and PRs
#
# WHY THIS EXISTS:
#   When issues/PRs are POSTed to GitHub with `assignees: [...]`, GitHub
#   silently DROPS any assignee that isn't currently a member of the target org.
#   Even after that person later accepts the org invitation, they are NOT
#   auto-assigned to historical issues.
#
# WHEN TO RUN:
#   - At least once 24h after sending invitations (08a) so most people have accepted
#   - Again right before cutover (15-cutover.sh) to catch late acceptances
#   - Optionally on a cron until everyone has accepted
#
# WHAT IT DOES:
#   For every target issue/PR with a `<!-- cf-mirror: ... -->` marker, it
#   re-reads the source's assignees and PATCHes the target. Members who are
#   still pending will be silently dropped again — re-run the script later.
#
# Idempotent and safe to re-run.
#
# Usage:
#   ./12-reassign.sh                 # all repos with mirrored issues/PRs
#   ./12-reassign.sh <repo-name>     # just one repo

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"
preflight

# Helper: extract source number from cf-mirror marker in body
# Issue marker:  <!-- cf-mirror: cyberfabric/repo#123 -->
# PR marker:     <!-- cf-mirror: cyberfabric/repo#PR123 -->
extract_source_number() {
  local body="$1" prefix="$2"   # prefix is "" for issues, "PR" for PRs
  echo "$body" | grep -oE "cf-mirror: ${SOURCE_ORG}/[^#]+#${prefix}[0-9]+ -->" \
    | head -1 | grep -oE "#${prefix}[0-9]+" | tr -d "#${prefix}"
}

reassign_one_repo() {
  local REPO="$1"
  log "Re-applying assignees in ${REPO}"

  local UPDATED=0 SKIPPED=0 MISSING=0

  # ── Issues ────────────────────────────────────────────────────────────────
  while read -r issue; do
    [ -z "$issue" ] && continue
    tgt_num=$(echo "$issue" | jq -r '.number')
    body=$(echo "$issue" | jq -r '.body // ""')

    # Only process issues we migrated (have the marker)
    if ! echo "$body" | grep -q "cf-mirror: ${SOURCE_ORG}/${REPO}#"; then
      continue
    fi

    src_num=$(extract_source_number "$body" "")
    [ -z "$src_num" ] && { MISSING=$((MISSING + 1)); continue; }

    # Fetch source assignees
    src_assignees=$(gh api "repos/${SOURCE_ORG}/${REPO}/issues/${src_num}" \
      --jq '[.assignees[].login]' 2>/dev/null || echo "[]")

    if [ "$src_assignees" = "[]" ] || [ -z "$src_assignees" ]; then
      SKIPPED=$((SKIPPED + 1))
      continue
    fi

    # Apply to target (non-members are silently dropped by GitHub)
    gh api "repos/${TARGET_ORG}/${REPO}/issues/${tgt_num}" \
      -X PATCH --input - <<< "{\"assignees\": ${src_assignees}}" >/dev/null 2>&1 || true

    # Read back and check if all were applied
    actual=$(gh api "repos/${TARGET_ORG}/${REPO}/issues/${tgt_num}" \
      --jq '[.assignees[].login]' 2>/dev/null)
    expected_count=$(echo "$src_assignees" | jq 'length')
    actual_count=$(echo "$actual" | jq 'length')

    UPDATED=$((UPDATED + 1))
    if [ "$actual_count" -lt "$expected_count" ]; then
      # Identify dropped assignees
      dropped=$(jq -n --argjson e "$src_assignees" --argjson a "$actual" \
        '$e - $a | join(", ")')
      warn "  issue #${tgt_num}: applied ${actual_count}/${expected_count} — still pending: ${dropped}"
    else
      echo "  ✓ issue #${tgt_num}: ${actual_count} assignee(s)"
    fi
    pause 0.3
  done < <(gh api "repos/${TARGET_ORG}/${REPO}/issues?state=all&per_page=100" \
    --paginate --jq '.[] | select(.pull_request == null)' 2>/dev/null)

  # ── Open PRs ──────────────────────────────────────────────────────────────
  while read -r pr; do
    [ -z "$pr" ] && continue
    tgt_num=$(echo "$pr" | jq -r '.number')
    body=$(echo "$pr" | jq -r '.body // ""')

    if ! echo "$body" | grep -q "cf-mirror: ${SOURCE_ORG}/${REPO}#PR"; then
      continue
    fi

    src_num=$(extract_source_number "$body" "PR")
    [ -z "$src_num" ] && { MISSING=$((MISSING + 1)); continue; }

    src_assignees=$(gh api "repos/${SOURCE_ORG}/${REPO}/issues/${src_num}" \
      --jq '[.assignees[].login]' 2>/dev/null || echo "[]")

    if [ "$src_assignees" = "[]" ] || [ -z "$src_assignees" ]; then
      SKIPPED=$((SKIPPED + 1))
      continue
    fi

    gh api "repos/${TARGET_ORG}/${REPO}/issues/${tgt_num}" \
      -X PATCH --input - <<< "{\"assignees\": ${src_assignees}}" >/dev/null 2>&1 || true

    actual=$(gh api "repos/${TARGET_ORG}/${REPO}/issues/${tgt_num}" \
      --jq '[.assignees[].login]' 2>/dev/null)
    expected_count=$(echo "$src_assignees" | jq 'length')
    actual_count=$(echo "$actual" | jq 'length')

    UPDATED=$((UPDATED + 1))
    if [ "$actual_count" -lt "$expected_count" ]; then
      dropped=$(jq -n --argjson e "$src_assignees" --argjson a "$actual" \
        '$e - $a | join(", ")')
      warn "  PR #${tgt_num}: applied ${actual_count}/${expected_count} — still pending: ${dropped}"
    else
      echo "  ✓ PR #${tgt_num}: ${actual_count} assignee(s)"
    fi
    pause 0.3
  done < <(gh api "repos/${TARGET_ORG}/${REPO}/pulls?state=open&per_page=100" \
    --paginate --jq '.[]' 2>/dev/null)

  ok "${REPO}: updated=${UPDATED} skipped_no_assignees=${SKIPPED} missing_marker=${MISSING}"
}

# Repos that had issues / open PRs (everything else has nothing to re-assign)
DEFAULT_REPOS=(
  cyberware-rust cyber-insight cyberware-frontx cyber-constructor
  cf-cli cf-template-rust governance cf-docs
  cyber-arc cyber-insight-front DNA cyberware-csharp
  cyber-wiki cyber-wiki-back cyber-wiki-front cyber-constructor-app
  demo-repository cyberfabric-courses
)

if [ $# -ge 1 ]; then
  reassign_one_repo "$1"
else
  for r in "${DEFAULT_REPOS[@]}"; do
    reassign_one_repo "$r"
  done
fi

echo ""
log "Re-assignment pass complete."
log "If any assignees are still pending (see warnings above), re-run this script"
log "after those members accept their org invitations."
