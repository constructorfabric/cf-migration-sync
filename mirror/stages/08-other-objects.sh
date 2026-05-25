#!/usr/bin/env bash
# mirror/stages/08-other-objects.sh
# Inventory objects that require manual action:
#   - GitHub Projects (no free-tier API for creating them)
#   - Installed GitHub Apps
#   - Wiki pages (per repo)
#   - Org-level webhooks
#
# Does NOT mirror any of these automatically.
# Writes state/other-objects.yaml with manual_action_required=true.
#
# Usage:
#   SOURCE_ORG=cyberfabric TARGET_ORG=constructorfabric \
#   GH_TOKEN=xxx GH_TOKEN_SOURCE=xxx \
#   ./mirror/stages/08-other-objects.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

TARGET_ORG="${TARGET_ORG:-constructorfabric}"
STATE_FILE="$REPO_ROOT/state/other-objects.yaml"

# ---------------------------------------------------------------------------
main() {
  check_dry_run "$@"
  preflight

  log "Stage 08 — other-objects inventory starting"

  state_init "$STATE_FILE" "08-other-objects"

  local items="[]"
  local ts
  ts="$(now)"

  # ---- 1. GitHub Projects (org-level) -----------------------------------
  log "Fetching GitHub Projects from $SOURCE_ORG..."
  local projects
  # Try v2 projects via GraphQL
  projects="$(ghsrc api graphql \
    -f query='query($org:String!){organization(login:$org){projectsV2(first:20){nodes{id title url number}}}}' \
    -f org="$SOURCE_ORG" \
    2>/dev/null | jq '.data.organization.projectsV2.nodes // []' || echo '[]')"

  local project_count
  project_count="$(echo "$projects" | jq 'length')"
  log "Found $project_count GitHub Projects (v2)"

  while IFS= read -r proj; do
    local title
    title="$(echo "$proj" | jq -r '.title')"
    local url
    url="$(echo "$proj" | jq -r '.url')"
    local number
    number="$(echo "$proj" | jq -r '.number')"

    items="$(echo "$items" | jq \
      --arg type  "github_project_v2" \
      --arg name  "$title" \
      --arg url   "$url" \
      --argjson n "$number" \
      --arg ts    "$ts" \
      '. + [{
        "type":                  $type,
        "name":                  $name,
        "source_url":            $url,
        "source_number":         $n,
        "status":                "inventory",
        "manual_action_required": true,
        "reason":                "GitHub Projects cannot be created via API on free plan",
        "inventoried_at":        $ts
      }]')"
  done < <(echo "$projects" | jq -c '.[]' 2>/dev/null || true)

  # ---- 2. Installed GitHub Apps -----------------------------------------
  log "Fetching installed GitHub Apps on $SOURCE_ORG..."
  local apps
  apps="$(ghsrc api "orgs/$SOURCE_ORG/installations" \
    2>/dev/null | jq '.installations // []' || echo '[]')"

  local app_count
  app_count="$(echo "$apps" | jq 'length')"
  log "Found $app_count installed GitHub Apps"

  while IFS= read -r app; do
    local app_name
    app_name="$(echo "$app" | jq -r '.app_slug // .app_id // "unknown"')"
    local app_id
    app_id="$(echo "$app" | jq -r '.id')"

    items="$(echo "$items" | jq \
      --arg type  "github_app" \
      --arg name  "$app_name" \
      --argjson id "$app_id" \
      --arg ts    "$ts" \
      '. + [{
        "type":                  $type,
        "name":                  $name,
        "source_installation_id": $id,
        "status":                "inventory",
        "manual_action_required": true,
        "reason":                "GitHub App installations must be authorized by the app owner",
        "inventoried_at":        $ts
      }]')"
  done < <(echo "$apps" | jq -c '.[]' 2>/dev/null || true)

  # ---- 3. Org-level webhooks --------------------------------------------
  log "Fetching org webhooks from $SOURCE_ORG..."
  local webhooks
  webhooks="$(ghsrc api "orgs/$SOURCE_ORG/hooks" \
    2>/dev/null || echo '[]')"

  local webhook_count
  webhook_count="$(echo "$webhooks" | jq 'length')"
  log "Found $webhook_count org webhooks"

  while IFS= read -r hook; do
    local hook_name
    hook_name="$(echo "$hook" | jq -r '.name // "web"')"
    local hook_url
    hook_url="$(echo "$hook" | jq -r '.config.url // "unknown"')"
    local hook_id
    hook_id="$(echo "$hook" | jq -r '.id')"

    items="$(echo "$items" | jq \
      --arg type  "org_webhook" \
      --arg name  "$hook_name" \
      --arg url   "$hook_url" \
      --argjson id "$hook_id" \
      --arg ts    "$ts" \
      '. + [{
        "type":                  $type,
        "name":                  $name,
        "source_id":             $id,
        "config_url":            $url,
        "status":                "inventory",
        "manual_action_required": true,
        "reason":                "Webhook secrets cannot be read via API; must reconfigure manually",
        "inventoried_at":        $ts
      }]')"
  done < <(echo "$webhooks" | jq -c '.[]' 2>/dev/null || true)

  # ---- 4. Wiki pages (per repo) ----------------------------------------
  log "Checking wikis across repos in $SOURCE_ORG..."
  local repos
  repos="$(gh_paginate ghsrc "orgs/$SOURCE_ORG/repos")"

  while IFS= read -r repo; do
    local repo_name
    repo_name="$(echo "$repo" | jq -r '.name')"
    local has_wiki
    has_wiki="$(echo "$repo" | jq -r '.has_wiki // false')"

    if [[ "$has_wiki" == "true" ]]; then
      # Try to detect if wiki actually has content (attempt clone check)
      local wiki_url="https://github.com/$SOURCE_ORG/$repo_name.wiki.git"

      items="$(echo "$items" | jq \
        --arg type  "wiki" \
        --arg name  "$repo_name wiki" \
        --arg url   "$wiki_url" \
        --arg ts    "$ts" \
        '. + [{
          "type":                  $type,
          "name":                  $name,
          "source_url":            $url,
          "status":                "inventory",
          "manual_action_required": true,
          "reason":                "Wiki repos can be mirrored separately via git clone <repo>.wiki.git",
          "inventoried_at":        $ts
        }]')"
    fi
  done < <(echo "$repos" | jq -c '.[]' 2>/dev/null || true)

  # ---- 5. Write state file ----------------------------------------------
  local item_count
  item_count="$(echo "$items" | jq 'length')"

  local tmp
  tmp="$(mktemp)"
  jq --argjson items "$items" \
     --argjson total "$item_count" \
    '.items = $items |
     .stats.total   = $total |
     .stats.synced  = 0 |
     .stats.pending = $total |
     .stats.failed  = 0' \
    "$STATE_FILE" > "$tmp"
  mv "$tmp" "$STATE_FILE"

  ok "Stage 08 complete — inventoried $item_count objects requiring manual action"

  log "Summary:"
  echo "$items" | jq -r 'group_by(.type) | .[] | "  \(.[0].type): \(length)"' >&2

  if [[ "$DRY_RUN" -eq 0 ]]; then
    commit_state "mirror: state after stage 08 (other-objects) [skip ci]"
  fi
}

main "$@"
