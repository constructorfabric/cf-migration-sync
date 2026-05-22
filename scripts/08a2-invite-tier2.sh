#!/usr/bin/env bash
# 08a2-invite-tier2.sh — Tier 2: invite before issue migration starts
# These users have open issue assignments and should be in the org before
# 05-migrate-issues.sh runs so their assignee links are preserved.

set -euo pipefail

USERS=(
  hyphen-2025    # 5 open issues in cyberware-rust
  pr0tey         # 5 open issues; Backend Arch + Governance
  akshatjhalani  # 5 open issues in cyberware-rust
  alizid10       # 5 open issues in cyberware-rust
  ainetx         # 4 open issues; Backend Architects
  dominic1988-lgtm  # 4 open issues in cyberware-rust
  nonameffh      # 4 open issues; Backend Arch + Governance
  Last-Christmas # 4 open issues; Frontend Architects
  gs-layer       # 3 open issues in cyberware-frontx
  modcrafter77   # 3 open issues in cyberware-rust
  jalankulkija   # 3 open issues in cyberware-rust
  ffedoroff      # 3 open issues; Backend Architects
  yoskini        # 2 open issues in cyberware-rust
  mattgarmon     # 2 open issues in cyberware-rust
  tscbmstubp     # 2 open issues in cyberware-frontx
)

for USER in "${USERS[@]}"; do
  echo "Inviting ${USER}..."
  USER_ID=$(gh api "users/${USER}" --jq '.id')
  gh api "orgs/constructorfabric/invitations" \
    -X POST \
    -F invitee_id="$USER_ID" \
    -f role="direct_member" || true
done