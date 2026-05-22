#!/usr/bin/env bash
# 00-check-prereqs.sh — verify environment is ready for migration
#
# Checks:
#   - gh, git, jq installed
#   - GH_TOKEN env var set
#   - Token can read cyberfabric AND write to constructorfabric
#   - Token has required scopes (repo, admin:org)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

preflight

log "Verifying token can access both orgs..."
ghsrc api "orgs/${SOURCE_ORG}" --jq '.login' >/dev/null \
  && ok "Read access to ${SOURCE_ORG}" \
  || { err "Cannot read ${SOURCE_ORG} — check token scopes"; exit 1; }

gh api "orgs/${TARGET_ORG}" --jq '.login' >/dev/null \
  && ok "Read access to ${TARGET_ORG}" \
  || { err "Cannot read ${TARGET_ORG} — check token scopes"; exit 1; }

log "Verifying token scopes..."
SCOPES=$(curl -sI -H "Authorization: token ${GH_TOKEN}" https://api.github.com/user \
  | tr -d '\r' | awk -F': ' 'tolower($1)=="x-oauth-scopes" {print $2}')
echo "  Token scopes: ${SCOPES}"

for scope in repo admin:org; do
  if echo "${SCOPES}" | grep -qw "${scope}"; then
    ok "Has scope: ${scope}"
  else
    err "MISSING scope: ${scope} — regenerate token at https://github.com/settings/tokens"
    exit 1
  fi
done

log "Listing source repos to confirm visibility..."
COUNT=$(list_source_repos | wc -l | tr -d ' ')
ok "Found ${COUNT} repos in ${SOURCE_ORG}"

log "All prerequisites OK. You can proceed to 01-mirror-all-repos.sh"
