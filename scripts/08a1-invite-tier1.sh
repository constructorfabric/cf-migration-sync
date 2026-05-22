#!/usr/bin/env bash
# 08a1-invite-tier1.sh — Tier 1: highest open-issue count, invite IMMEDIATELY
# These users own the most active open issues — inviting first gives them maximum
# time to accept before 05-migrate-issues.sh runs.

set -euo pipefail

USERS=(
  aleksdotbar    # 34 open issues in cyber-insight
  Artifizer      # 22 open issues in cyberware-rust; org owner
  GeraBart       # 21 open issues in cyberware-frontx
  aviator5       # 18 open issues in cyberware-rust
  mitasovr       # 18 open issues in cyber-insight
  MikeFalcon77   # 15 open issues in cyberware-rust
  cyberantonz    # 16 open issues in cyber-insight
  Gregory91G     # 12 open issues in cyber-insight
  mozhaev-dev    # 10 open issues in cyber-insight
  Bechma         # 10 open issues in cyberware-rust
  striped-zebra-dev  # 9 open issues in cyberware-rust
)

for USER in "${USERS[@]}"; do
  echo "Inviting ${USER}..."
  USER_ID=$(gh api "users/${USER}" --jq '.id')
  gh api "orgs/constructorfabric/invitations" \
    -X POST \
    -F invitee_id="$USER_ID" \
    -f role="direct_member" || true
done