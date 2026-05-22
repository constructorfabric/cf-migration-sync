#!/usr/bin/env bash
# 10-apply-org-settings.sh — apply non-2FA org settings via API
#
# NOTE: 2FA enforcement must be enabled manually in the GitHub UI at
#   https://github.com/organizations/constructorfabric/settings/auth
# (the API does not expose that toggle on the free plan).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"
preflight

log "Applying org settings to ${TARGET_ORG}..."
gh api "orgs/${TARGET_ORG}" -X PATCH \
  -f default_repository_permission="none" \
  -F members_can_fork_private_repositories=true \
  -F members_allowed_repository_creation_type="all" \
  --jq '{default_repository_permission, members_can_fork_private_repositories, members_allowed_repository_creation_type}'

ok "Settings applied"
warn "Remember: enable 2FA enforcement manually at https://github.com/organizations/${TARGET_ORG}/settings/auth"
