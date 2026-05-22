#!/usr/bin/env bash
# 04-copy-milestones.sh — copy all milestones from source to target repos
#
# Run BEFORE 05-migrate-issues.sh so issues can reference milestones.
# Idempotent: milestones are matched by title; existing ones are skipped.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"
preflight

log "Copying milestones for all repos..."

list_source_repos | while IFS= read -r REPO; do
  CREATED=0
  while read -r ms; do
    [ -z "$ms" ] && continue
    title=$(echo "$ms" | jq -r '.title')
    state=$(echo "$ms" | jq -r '.state')
    desc=$(echo "$ms"  | jq -r '.description // ""')
    due=$(echo "$ms"   | jq -r '.due_on // empty')

    # Skip if a milestone with the same title already exists in target
    EXISTS=$(gh api "repos/${TARGET_ORG}/${REPO}/milestones?state=all" --paginate \
      --jq ".[] | select(.title==\"${title}\") | .number" 2>/dev/null | head -1)
    [ -n "$EXISTS" ] && continue

    PAYLOAD=$(jq -n --arg t "$title" --arg s "$state" --arg d "$desc" \
      '{title:$t,state:$s,description:$d}')
    [ -n "$due" ] && PAYLOAD=$(echo "$PAYLOAD" | jq --arg due "$due" '.+{due_on:$due}')

    gh api "repos/${TARGET_ORG}/${REPO}/milestones" \
      -X POST --input - <<< "$PAYLOAD" >/dev/null 2>&1 \
      && CREATED=$((CREATED + 1)) || true
  done < <(gh api "repos/${SOURCE_ORG}/${REPO}/milestones?state=all" --paginate --jq '.[]' 2>/dev/null)
  [ "$CREATED" -gt 0 ] && echo "  ${REPO}: ${CREATED} milestones created"
done

ok "Milestones copied"
