#!/usr/bin/env bash
# 03-copy-labels.sh — copy all labels from source repos to target repos
#
# Run BEFORE 05-migrate-issues.sh so issues can be tagged correctly.
# Idempotent: existing labels are updated to match source color/description.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"
preflight

log "Copying labels for all repos..."

list_source_repos | while IFS= read -r REPO; do
  COUNT=0
  while read -r lbl; do
    [ -z "$lbl" ] && continue
    name=$(echo "$lbl"  | jq -r '.name')
    color=$(echo "$lbl" | jq -r '.color')
    desc=$(echo "$lbl"  | jq -r '.description // ""')
    encoded=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$name")

    # Try create; if it exists (422), update it
    gh api "repos/${TARGET_ORG}/${REPO}/labels" \
      -X POST -f name="$name" -f color="$color" -f description="$desc" \
      >/dev/null 2>&1 \
    || gh api "repos/${TARGET_ORG}/${REPO}/labels/${encoded}" \
      -X PATCH -f color="$color" -f description="$desc" \
      >/dev/null 2>&1 || true
    COUNT=$((COUNT + 1))
  done < <(gh api "repos/${SOURCE_ORG}/${REPO}/labels" --paginate --jq '.[]' 2>/dev/null)
  [ "$COUNT" -gt 0 ] && echo "  ${REPO}: ${COUNT} labels"
done

ok "Labels copied"
