#!/usr/bin/env bash
# 08a3-invite-tier3.sh — Tier 3: special permissions (team leads, org owners)
# Invite regardless of issue assignment count — these users manage repos or teams.

set -euo pipefail

USERS=(
  vzhuman        # Org Owner
  cyberdima      # insight-app-maintainers (push to cyber-insight)
  bukem          # insight-app-maintainers (push to cyber-insight)
  dzarlax        # insight-app-maintainers (push to cyber-insight)
  dobrovols      # Governance + Security
  netjerikhet    # Governance + Security
  orivaris       # Security
  binarycode     # Backend Architects
  entropyshift   # Backend Architects
  capybutler     # Backend Architects + Governance
  frontgeeks     # Governance
  lobster40      # Governance
  enridis        # Governance
  lavacitalola   # Governance
  pm-pltfrm      # Governance
  getahead       # Frontend Architects
  necobaka       # Frontend Architects
  voidtopixel    # Frontend Architects
  abyssal-potato # Frontend Architects
  eddeisling     # Frontend Architects
  m231-a         # Frontend Architects
)

for USER in "${USERS[@]}"; do
  echo "Inviting ${USER}..."
  USER_ID=$(gh api "users/${USER}" --jq '.id')
  gh api "orgs/constructorfabric/invitations" \
    -X POST \
    -F invitee_id="$USER_ID" \
    -f role="direct_member" || true
done
