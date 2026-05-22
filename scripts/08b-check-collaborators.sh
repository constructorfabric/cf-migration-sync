#!/usr/bin/env bash
# 08b-check-collaborators.sh — discover which repos each outside collaborator can access
#
# Output: a list of "<collab> <repo>" pairs to feed into a follow-up script.
# This is a READ-ONLY discovery step. Outside collaborators are added in 08c.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"
preflight

COLLABS=(beyond-event-horizon dingoatemytokens mitevsyavor)

log "Discovering repo access for each outside collaborator..."

for collab in "${COLLABS[@]}"; do
  echo ""
  echo "=== ${collab} ==="
  list_source_repos | while IFS= read -r REPO; do
    PERM=$(ghsrc api "repos/${SOURCE_ORG}/${REPO}/collaborators/${collab}/permission" \
      --jq '.permission' 2>/dev/null || echo "")
    [ -n "$PERM" ] && echo "  ${REPO}: ${PERM}"
  done
done

echo ""
log "To grant access in target, use:"
echo "  gh api repos/${TARGET_ORG}/<REPO>/collaborators/<COLLAB> -X PUT -f permission='<PERMISSION>'"
