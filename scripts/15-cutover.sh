#!/usr/bin/env bash
# 15-cutover.sh — final cutover from cyberfabric to constructorfabric
#
# Steps:
#   1. Freeze cyberfabric (set default permission to read-only)
#   2. Trigger final continuous-sync workflow run and wait for completion
#   3. Disable the continuous-sync schedule
#
# Interactive: prompts for confirmation at each step.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"
preflight

SYNC_REPO="${TARGET_ORG}/cf-migration-sync"

# ── Step 1: Freeze source org ────────────────────────────────────────────────
log "Step 1/3 — Freeze ${SOURCE_ORG} (set default permission to 'read')"
confirm "Set default_repository_permission=read on ${SOURCE_ORG}?" || { warn "skipped"; exit 0; }

ghsrc api "orgs/${SOURCE_ORG}" -X PATCH -f default_repository_permission=read \
  --jq '.default_repository_permission' && ok "${SOURCE_ORG} is now read-only"

echo ""
warn "Communicate to your team NOW: ${SOURCE_ORG} is read-only. Use ${TARGET_ORG}."
read -r -p "Press Enter when team has been notified..."

# ── Step 2: Trigger final sync ───────────────────────────────────────────────
log "Step 2/3 — Trigger final continuous-sync run"
confirm "Trigger continuous-sync.yml in ${SYNC_REPO}?" || { warn "skipped"; exit 0; }

gh workflow run continuous-sync.yml --repo "${SYNC_REPO}"
ok "Workflow triggered"

log "Waiting 10s for the run to register..."
sleep 10

RUN_ID=$(gh run list --repo "${SYNC_REPO}" --workflow=continuous-sync.yml \
  --limit 1 --json databaseId --jq '.[0].databaseId')
log "Watching run ${RUN_ID}..."
gh run watch "${RUN_ID}" --repo "${SYNC_REPO}" --exit-status \
  && ok "Final sync completed" \
  || { err "Final sync failed — investigate before disabling"; exit 1; }

# ── Step 3: Disable the schedule ─────────────────────────────────────────────
log "Step 3/3 — Disable the continuous-sync workflow schedule"
confirm "Disable continuous-sync.yml? (You can re-enable later if needed)" || { warn "skipped"; exit 0; }

gh workflow disable continuous-sync.yml --repo "${SYNC_REPO}"
ok "Workflow disabled"

echo ""
log "Cutover complete. Run ./validate.sh to verify final state."
