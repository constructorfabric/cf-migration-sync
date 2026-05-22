#!/usr/bin/env bash
# 07-migrate-releases.sh — copy GitHub Releases (metadata) to target repos
#
# Tags must already exist (they're mirrored in Phase 1). This script attaches
# release notes / draft / prerelease flags to each tag.
# Idempotent: existing releases for a tag are skipped.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"
preflight

log "Copying releases for all repos..."

list_source_repos | while IFS= read -r REPO; do
  CREATED=0
  while read -r release; do
    [ -z "$release" ] && continue
    tag=$(echo "$release" | jq -r '.tag_name')
    name=$(echo "$release" | jq -r '.name // ""')
    body=$(echo "$release" | jq -r '.body // ""')
    draft=$(echo "$release" | jq -r '.draft')
    prerelease=$(echo "$release" | jq -r '.prerelease')

    gh api "repos/${TARGET_ORG}/${REPO}/releases" \
      -X POST \
      -f tag_name="$tag" \
      -f name="$name" \
      -f body="$body" \
      -F draft="$draft" \
      -F prerelease="$prerelease" >/dev/null 2>&1 \
      && CREATED=$((CREATED + 1)) || true
  done < <(gh api "repos/${SOURCE_ORG}/${REPO}/releases" --paginate --jq '.[]' 2>/dev/null)
  [ "$CREATED" -gt 0 ] && echo "  ${REPO}: ${CREATED} releases"
done

ok "Releases copied"
