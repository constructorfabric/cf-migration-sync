#!/usr/bin/env bash
# 02-copy-repo-settings.sh — copy topics from each source repo to its target counterpart
#
# Idempotent.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"
preflight

log "Copying topics for all repos..."

list_source_repos | while IFS= read -r REPO; do
  TOPICS=$(gh api "repos/${SOURCE_ORG}/${REPO}/topics" --jq '.names' 2>/dev/null || echo "[]")
  if [ "$TOPICS" = "[]" ]; then
    continue
  fi
  echo "  ${REPO} ← ${TOPICS}"
  gh api "repos/${TARGET_ORG}/${REPO}/topics" \
    -X PUT --input - <<< "{\"names\": $TOPICS}" >/dev/null
done

ok "Topics applied"
