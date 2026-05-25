#!/usr/bin/env bash
# mirror/stages/03-org-metadata.sh
# Copy org-level settings from source org to target org.
# State file: state/org-metadata.yaml
#
# Settings synced (all via PATCH /orgs/{org}):
#   - Member privilege settings (permissions, repo/pages creation, etc.)
#   - Org profile (description, company, location, website, twitter)
#
# Not synced intentionally:
#   - name          — changes org URL; identity field
#   - email         — affects billing notifications; identity field
#   - billing_email — sensitive; identity field
#
# To lock a setting to a specific value regardless of source, add it under
# stage_03_org_metadata.locked_settings in mirror/config.json.
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
# Settings table — "field_name  type" pairs.
# type: string | bool
#   string → passed with -f (JSON string value)
#   bool   → passed with -F (type-inferred; "true"/"false" become JSON booleans)
#
# To add a new setting: append a line here. No other code changes needed.
# To lock a setting's value: add it to config.json locked_settings.
# ---------------------------------------------------------------------------
SYNC_SETTINGS=(
  # -- Member privilege settings --
  "default_repository_permission            string"
  "members_can_create_repositories          bool"
  "members_can_create_public_repositories   bool"
  "members_can_create_private_repositories  bool"
  "members_can_fork_private_repositories    bool"
  "web_commit_signoff_required              bool"
  "members_can_create_pages                 bool"
  "members_can_create_public_pages          bool"
  "members_can_create_private_pages         bool"
  "has_organization_projects                bool"
  "has_repository_projects                  bool"
  # -- Org profile (non-identity fields) --
  "description                              string"
  "company                                  string"
  "location                                 string"
  "blog                                     string"
  "twitter_username                         string"
)

# ---------------------------------------------------------------------------
main() {
  check_dry_run "$@"
  preflight

  log "Stage 03 — org-metadata starting"

  state_init "$STATE_FILE" "03-org-metadata"

  # ---- 1. Fetch source org settings ----------------------------------------
  log "Fetching source org settings from $SOURCE_ORG..."
  local src_org
  src_org="$(ghsrc api "orgs/$SOURCE_ORG" 2>/dev/null || echo '{}')"
  # RC-3: guard against extra runner output appended to stdout
  src_org="$(echo "$src_org" | jq -rs '.[0] // {}' 2>/dev/null || echo '{}')"

  # ---- 2. Load policy locks from config ------------------------------------
  # RC-4: use has() — NOT // — so that false values are correctly detected.
  # jq's // operator treats false as falsy: `false // empty` = empty.
  local locked_settings
  locked_settings="$(jq '.stage_03_org_metadata.locked_settings // {}' \
    "$MIRROR_CONFIG" 2>/dev/null || echo '{}')"
  local lock_count
  lock_count="$(echo "$locked_settings" | jq 'keys | length')"
  if [[ "$lock_count" -gt 0 ]]; then
    log "Policy locks active ($lock_count): $(echo "$locked_settings" | jq -r 'keys | join(", ")')"
  else
    log "No policy locks configured"
  fi

  # ---- 3. Sync each setting -------------------------------------------------
  local ts
  ts="$(now)"
  local items="[]"
  local skipped=0

  for setting_def in "${SYNC_SETTINGS[@]}"; do
    local field type
    field="$(echo "$setting_def" | awk '{print $1}')"
    type="$(echo  "$setting_def" | awk '{print $2}')"

    # Extract value from source org JSON.
    # .[$f] == null when the field is absent OR explicitly null → skip.
    # tostring converts false→"false", true→"true", strings stay as-is.
    local src_val
    src_val="$(echo "$src_org" | jq -r --arg f "$field" \
      'if .[$f] != null then .[$f] | tostring else empty end' \
      2>/dev/null || true)"

    if [[ -z "$src_val" ]]; then
      skipped=$((skipped + 1))
      continue
    fi

    # Check for policy lock — RC-4: has() correctly handles false values.
    local locked_val
    locked_val="$(echo "$locked_settings" | jq -r --arg f "$field" \
      'if has($f) then .[$f] | tostring else empty end' \
      2>/dev/null || true)"

    local effective_val="$src_val"
    if [[ -n "$locked_val" ]]; then
      warn "POLICY LOCK: $field = '$locked_val' (source '$src_val' overridden by config)"
      effective_val="$locked_val"
    fi

    items="$(_apply_setting "$items" "$field" "$effective_val" "$ts" "$type")"
  done

  # ---- 4. Write state -------------------------------------------------------
  local total synced failed
  total="$(echo "$items" | jq 'length')"
  synced="$(echo "$items" | jq '[.[] | select(.status == "synced")] | length')"
  failed="$(echo "$items" | jq '[.[] | select(.status == "failed")] | length')"

  local tmp
  tmp="$(mktemp)"
  jq --argjson items "$items" \
    '.items = $items |
     .stats.total   = ($items | length) |
     .stats.synced  = ($items | map(select(.status == "synced")) | length) |
     .stats.pending = 0 |
     .stats.failed  = ($items | map(select(.status == "failed")) | length)' \
    "$STATE_FILE" > "$tmp"
  mv "$tmp" "$STATE_FILE"

  log "Stage 03 complete — applied=$total synced=$synced failed=$failed skipped=$skipped (not in source API response)"

  if [[ "$DRY_RUN" -eq 0 ]]; then
    commit_state "mirror: state after stage 03 (org-metadata) [skip ci]"
  fi
}

# ---------------------------------------------------------------------------
# _apply_setting — apply one org setting and return the updated items array
# _apply_setting <items_json> <field> <value> <ts> <type>
#   type: "string" (default) | "bool"
#     string → -f flag: value sent as JSON string
#     bool   → -F flag: value type-inferred ("true"/"false" → JSON booleans)
_apply_setting() {
  local items="$1"
  local field="$2"
  local value="$3"
  local ts="$4"
  local type="${5:-string}"

  log "Applying $field = $value to $TARGET_ORG..."

  if dry_run_skip "gh api orgs/$TARGET_ORG --method PATCH ${type}:$field=$value"; then
    echo "$items" | jq --arg name "$field" --arg value "$value" --arg ts "$ts" \
      '. + [{"name": $name, "value": $value, "status": "synced", "synced_at": $ts}]'
    return 0
  fi

  local result
  if [[ "$type" == "bool" ]]; then
    result="$(gh api "orgs/$TARGET_ORG" \
      --method PATCH \
      -F "$field=$value" \
      2>/dev/null || echo 'FAILED')"
  else
    result="$(gh api "orgs/$TARGET_ORG" \
      --method PATCH \
      -f "$field=$value" \
      2>/dev/null || echo 'FAILED')"
  fi

  local status
  if [[ "$result" == "FAILED" ]]; then
    warn "Failed to set $field on $TARGET_ORG"
    status="failed"
  else
    ok "Set $field = $value on $TARGET_ORG"
    status="synced"
  fi

  echo "$items" | jq \
    --arg name   "$field" \
    --arg value  "$value" \
    --arg status "$status" \
    --arg ts     "$ts" \
    '. + [{"name": $name, "value": $value, "status": $status, "synced_at": $ts}]'
}

main "$@"
