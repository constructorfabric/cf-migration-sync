#!/usr/bin/env bash
# 01-mirror-all-repos.sh — clone every source repo and push --mirror to target
#
# Creates the target repo if it doesn't exist, then mirrors all branches and tags.
# Empty source repos (e.g. cyberfabric-marketing) are skipped cleanly.
# Idempotent: safe to re-run; existing target repos are not re-created.
#
# Usage: ./01-mirror-all-repos.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"
preflight

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

log "Mirroring all ${SOURCE_ORG} repos → ${TARGET_ORG}"
log "Working dir: ${WORKDIR}"

list_source_repos | while IFS= read -r REPO; do
  echo ""
  log "Mirroring: ${REPO}"

  META=$(ghsrc api "repos/${SOURCE_ORG}/${REPO}")
  DESC=$(echo "$META" | jq -r '.description // ""')
  DEFAULT_BRANCH=$(echo "$META" | jq -r '.default_branch // "main"')

  # Create target repo if missing
  if gh repo view "${TARGET_ORG}/${REPO}" >/dev/null 2>&1; then
    ok "Target exists: ${TARGET_ORG}/${REPO}"
  else
    gh repo create "${TARGET_ORG}/${REPO}" --private --description "$DESC" >/dev/null
    ok "Created ${TARGET_ORG}/${REPO}"
  fi

  # Clone source mirror (empty repos will fail — skip them)
  if ! git clone --mirror \
      "https://x-access-token:${GH_TOKEN}@github.com/${SOURCE_ORG}/${REPO}.git" \
      "${WORKDIR}/${REPO}.git" 2>/dev/null; then
    warn "SKIP ${REPO}: empty or unreachable (target repo created but no refs)"
    continue
  fi

  pushd "${WORKDIR}/${REPO}.git" >/dev/null
  git remote set-url origin \
    "https://x-access-token:${GH_TOKEN}@github.com/${TARGET_ORG}/${REPO}.git"
  if ! git push --mirror 2>&1 | tail -5; then
    warn "mirror push failed (likely refs/pull/* rejection), retrying with explicit refspecs..."
    git config --unset remote.origin.mirror
    git push --prune origin \
      '+refs/heads/*:refs/heads/*' \
      '+refs/tags/*:refs/tags/*' 2>&1 | tail -5
  fi
  popd >/dev/null

  rm -rf "${WORKDIR}/${REPO}.git"

  gh api "repos/${TARGET_ORG}/${REPO}" \
    -X PATCH -f default_branch="$DEFAULT_BRANCH" >/dev/null 2>&1 || true

  ok "Mirrored: ${REPO} (default branch: ${DEFAULT_BRANCH})"
done

echo ""
log "Verifying counts..."
SRC=$(list_source_repos | wc -l | tr -d ' ')
TGT=$(gh api "orgs/${TARGET_ORG}/repos" --paginate --jq '.[].name' | wc -l | tr -d ' ')
echo "  Source: ${SRC}    Target: ${TGT}"
[ "$SRC" = "$TGT" ] && ok "All repos present" || warn "Count mismatch — inspect"
