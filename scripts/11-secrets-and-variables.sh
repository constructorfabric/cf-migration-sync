#!/usr/bin/env bash
# 11-secrets-and-variables.sh — list source secrets (names only) + copy variables (values)
#
# Secret VALUES cannot be read via API — they must be re-entered manually in the
# target org's settings UI. This script prints what to re-enter, then copies
# variables (whose values ARE readable) automatically.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"
preflight

# ── Print secret names to recreate manually ─────────────────────────────────
print_secrets() {
  local KIND="$1"   # actions | dependabot | codespaces
  echo ""
  echo "=== ${KIND} secrets (names only — recreate manually) ==="
  gh api "orgs/${SOURCE_ORG}/${KIND}/secrets" \
    --jq '.secrets[] | "  \(.name) (visibility: \(.visibility))"' 2>/dev/null \
    || echo "  (none or insufficient scope)"
}

print_secrets actions
print_secrets dependabot
print_secrets codespaces

echo ""
echo "To recreate these manually:"
echo "  https://github.com/organizations/${TARGET_ORG}/settings/secrets/actions"
echo ""

# ── Copy variables (values are readable) ─────────────────────────────────────
log "Copying org-level Actions variables..."
COPIED=0
while read -r var; do
  [ -z "$var" ] && continue
  name=$(echo "$var" | jq -r '.name')
  value=$(echo "$var" | jq -r '.value')
  visibility=$(echo "$var" | jq -r '.visibility')
  if gh api "orgs/${TARGET_ORG}/actions/variables" \
       -X POST -f name="$name" -f value="$value" -f visibility="$visibility" \
       >/dev/null 2>&1; then
    ok "variable: ${name}"
    COPIED=$((COPIED + 1))
  else
    # Already exists — update it
    gh api "orgs/${TARGET_ORG}/actions/variables/${name}" \
      -X PATCH -f value="$value" -f visibility="$visibility" >/dev/null 2>&1 \
      && echo "  ~ updated: ${name}" || warn "could not copy: ${name}"
  fi
done < <(gh api "orgs/${SOURCE_ORG}/actions/variables" --paginate --jq '.variables[]' 2>/dev/null)

log "Variables copied: ${COPIED}"
