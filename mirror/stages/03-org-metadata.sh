#!/usr/bin/env bash
# mirror/stages/03-org-metadata.sh
# Copy org-level settings from source org to target org.
# State file: state/org-metadata.yaml
#
# Settings copied:
#   - default_repository_permission
#   - members_can_create_repositories
#   - members_can_fork_private_repositories
#
# Note: the .github profile repo is handled by stage 02 (git mirror).
#
# Usage:
#   SOURCE_ORG=cyberfabric TARGET_ORG=constructorfabric \
#   GH_TOKEN=xxx GH_TOKEN_SOURCE=xxx \
#   ./mirror/stages/03-org-metadata.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

TARGET_ORG="${TARGET_ORG:-constructorfabric}"
STATE_FILE="$REPO_ROOT/state/org-metadata.yaml"

# ---------------------------------------------------------------------------
main() {
  check_dry_run "$@"
  preflight

  log "Stage 03 — org-metadata starting"

  state_init "$STATE_FILE" "03-org-metadata"

  # ---- 1. Fetch source org settings -------------------------------------
  log "Fetching source org settings from $SOURCE_ORG..."
  local src_org
  src_org="$(ghsrc api "orgs/$SOURCE_ORG" 2>/dev/null || echo '{}')"

  local default_repo_perm
  default_repo_perm="$(echo "$src_org" | jq -r '.default_repository_permission // "read"')"

  local members_can_create
  members_can_create="$(echo "$src_org" | jq -r '.members_can_create_repositories // false')"

  local members_can_fork_private
  members_can_fork_private="$(echo "$src_org" | jq -r '.members_can_fork_private_repositories // false')"

  log "Source settings:"
  log "  default_repository_permission: $default_repo_perm"
  log "  members_can_create_repositories: $members_can_create"
  log "  members_can_fork_private_repositories: $members_can_fork_private"

  # ---- 2. Apply to target org ------------------------------------------
  local ts
  ts="$(now)"
  local items="[]"

  # Apply default_repository_permission
  items="$(_apply_setting "$items" "default_repository_permission" \
    "$default_repo_perm" \
    "default_repository_permission" "$default_repo_perm" "$ts")"

  # Apply members_can_create_repositories
  items="$(_apply_setting "$items" "members_can_create_repositories" \
    "$members_can_create" \
    "members_can_create_repositories" "$members_can_create" "$ts")"

  # Apply members_can_fork_private_repositories
  items="$(_apply_setting "$items" "members_can_fork_private_repositories" \
    "$members_can_fork_private" \
    "members_can_fork_private_repositories" "$members_can_fork_private" "$ts")"

  # ---- 3. Write state ---------------------------------------------------
  local tmp
  tmp="$(mktemp)"
  jq --argjson items "$items" \
    '.items = $items |
     .stats.total   = ($items | length) |
     .stats.synced  = ($items | map(select(.status == "synced")) | length) |
     .stats.pending = ($items | map(select(.status == "pending")) | length) |
     .stats.failed  = ($items | map(select(.status == "failed")) | length)' \
    "$STATE_FILE" > "$tmp"
  mv "$tmp" "$STATE_FILE"

  log "Stage 03 complete"

  if [[ "$DRY_RUN" -eq 0 ]]; then
    commit_state "mirror: state after stage 03 (org-metadata) [skip ci]"
  fi
}

# ---------------------------------------------------------------------------
# _apply_setting — apply one org setting and return updated items array
# _apply_setting <items_json> <name> <value> <api_field> <api_value> <ts>
_apply_setting() {
  local items="$1"
  local name="$2"
  local value="$3"
  local api_field="$4"
  local api_value="$5"
  local ts="$6"

  log "Applying $name = $api_value to $TARGET_ORG..."

  if dry_run_skip "gh api orgs/$TARGET_ORG --method PATCH -f $api_field=$api_value"; then
    echo "$items" | jq --arg name "$name" --arg value "$value" --arg ts "$ts" \
      '. + [{"name": $name, "value": $value, "status": "synced", "synced_at": $ts}]'
    return 0
  fi

  local result
  result="$(gh api "orgs/$TARGET_ORG" \
    --method PATCH \
    -f "$api_field=$api_value" \
    2>/dev/null || echo 'FAILED')"

  local status
  if [[ "$result" == "FAILED" ]]; then
    warn "Failed to set $name on $TARGET_ORG"
    status="failed"
  else
    ok "Set $name = $api_value on $TARGET_ORG"
    status="synced"
  fi

  echo "$items" | jq \
    --arg name   "$name" \
    --arg value  "$value" \
    --arg status "$status" \
    --arg ts     "$ts" \
    '. + [{"name": $name, "value": $value, "status": $status, "synced_at": $ts}]'
}

main "$@"
