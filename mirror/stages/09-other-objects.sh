#!/usr/bin/env bash
# mirror/stages/09-other-objects.sh
# Inventory and partial mirror of objects requiring manual action or secrets.
#
# What this stage does:
#   CREATES in target (without secret credentials):
#     - Org webhooks       — created with empty secret; operator must add secret
#     - Repo webhooks      — created with empty secret per repo; operator must add secret
#
#   INVENTORIES only (manual_action_required=true):
#     - GitHub Projects v2 — cannot be created via API on free plan
#     - Installed GitHub Apps — require app owner authorization
#     - Wiki pages per repo — clone separately via git
#     - Actions secret NAMES — values are write-only; operator must recreate
#     - Dependabot secret NAMES — same
#     - Self-hosted runner names/labels — machines are external
#     - Deploy key titles + public keys — private keys are unreadable
#
# Modes (MIRROR_MODE):
#   full   — inventory the source AND create webhooks in the target (default).
#   export — inventory the source only; serialize all items (including full
#            webhook config) into state. NEVER contacts the target org.
#   import — read serialized items from state and create webhooks in the target.
#            NEVER contacts the source org. Inventory-only items are left as-is.
#
# NOT included here (handled by dedicated stages):
#   - Releases + assets  → stage 11 (mirror-releases)
#   - Branch protections → stage 12 (mirror-branch-protections)
#   - Actions variables  → stage 13 (mirror-actions-variables)
#
# Usage:
#   SOURCE_ORG=cyberfabric TARGET_ORG=constructorfabric \
#   GH_TOKEN=xxx GH_TOKEN_SOURCE=xxx \
#   MIRROR_MODE=full|export|import \
#   ./mirror/stages/09-other-objects.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

TARGET_ORG="${TARGET_ORG:-}"   # required; validated in preflight (no hardcoded default)
STATE_FILE="$REPO_ROOT/state/other-objects.yaml"

# ---------------------------------------------------------------------------
# _create_org_webhook <name> <url> <ct> <ssl> <active_json> <events_json>
# Creates an org webhook in the target if no webhook with the same URL exists.
# Echoes the resulting status (created_no_secret | failed). TARGET writes only.
_create_org_webhook() {
  local name="$1" url="$2" ct="$3" ssl="$4" active="$5" events="$6"
  local tgt_urls
  tgt_urls="$(gh api "orgs/$TARGET_ORG/hooks?per_page=100" \
    2>/dev/null | jq -rs '.[0] // [] | [.[].config.url // ""] | map(select(. != ""))' \
    2>/dev/null)" || tgt_urls='[]'
  if [[ -n "$(echo "$tgt_urls" | jq -r --arg u "$url" '.[] | select(. == $u)' 2>/dev/null || true)" ]]; then
    log "  Org webhook $url already exists in target — skipping"
    echo "created_no_secret"; return 0
  fi
  local _tmp result
  _tmp="$(mktemp)"
  jq -n --arg name "$name" --arg url "$url" --arg ct "$ct" --arg ssl "$ssl" \
    --argjson active "$active" --argjson events "$events" \
    '{"name":$name,"config":{"url":$url,"content_type":$ct,"insecure_ssl":$ssl},"events":$events,"active":$active}' > "$_tmp"
  result="$(gh api "orgs/$TARGET_ORG/hooks" --method POST --input "$_tmp" 2>/dev/null)" || result='FAILED'
  rm -f "$_tmp"
  if [[ "$result" == "FAILED" ]]; then
    warn "  Failed to create org webhook $url in $TARGET_ORG"; echo "failed"
  else
    ok "  Created org webhook: $url (secret must be set manually)"; echo "created_no_secret"
  fi
}

# _create_repo_webhook <repo> <url> <ct> <ssl> <active_json> <events_json>
_create_repo_webhook() {
  local repo_name="$1" url="$2" ct="$3" ssl="$4" active="$5" events="$6"
  local tgt_urls
  tgt_urls="$(gh api "repos/$TARGET_ORG/$repo_name/hooks?per_page=100" \
    2>/dev/null | jq -rs '.[0] // [] | [.[].config.url // ""] | map(select(. != ""))' \
    2>/dev/null)" || tgt_urls='[]'
  if [[ -n "$(echo "$tgt_urls" | jq -r --arg u "$url" '.[] | select(. == $u)' 2>/dev/null || true)" ]]; then
    log "  Repo webhook $url already exists in $TARGET_ORG/$repo_name — skipping"
    echo "created_no_secret"; return 0
  fi
  local _tmp result
  _tmp="$(mktemp)"
  jq -n --arg url "$url" --arg ct "$ct" --arg ssl "$ssl" \
    --argjson active "$active" --argjson events "$events" \
    '{"config":{"url":$url,"content_type":$ct,"insecure_ssl":$ssl},"events":$events,"active":$active}' > "$_tmp"
  result="$(gh api "repos/$TARGET_ORG/$repo_name/hooks" --method POST --input "$_tmp" 2>/dev/null)" || result='FAILED'
  rm -f "$_tmp"
  if [[ "$result" == "FAILED" ]]; then
    warn "  Failed to create repo webhook $url in $TARGET_ORG/$repo_name"; echo "failed"
  else
    ok "  Created repo webhook for $repo_name: $url"; echo "created_no_secret"
  fi
}

# ---------------------------------------------------------------------------
main() {
  check_dry_run "$@"
  preflight

  log "Stage 09 — other-objects starting (mode=$MIRROR_MODE)"
  state_init "$STATE_FILE" "09-other-objects"

  if in_import; then
    _import_other_objects
    ok "Stage 09 complete (import)"
    [[ "$DRY_RUN" -eq 0 ]] && commit_state "mirror: import stage 09 (other-objects) [skip ci]"
    return 0
  fi

  # ---- full + export: inventory the source --------------------------------
  local items="[]"
  local ts
  ts="$(now)"

  log "Fetching source repos from $SOURCE_ORG..."
  local repos
  repos="$(gh_paginate ghsrc "orgs/$SOURCE_ORG/repos")"

  # ---- 1. GitHub Projects (org-level) — inventory only -------------------
  log "Fetching GitHub Projects from $SOURCE_ORG..."
  local projects
  projects="$(ghsrc api graphql \
    -f query='query($org:String!){organization(login:$org){projectsV2(first:20){nodes{id title url number}}}}' \
    -f org="$SOURCE_ORG" \
    2>/dev/null | jq -rs '.[0].data.organization.projectsV2.nodes // []' 2>/dev/null)" || projects='[]'

  local project_count
  project_count="$(echo "$projects" | jq 'length' 2>/dev/null || echo 0)"
  log "Found $project_count GitHub Projects (v2)"

  while IFS= read -r proj; do
    local title url number
    title="$(echo  "$proj" | jq -r '.title')"
    url="$(echo    "$proj" | jq -r '.url')"
    number="$(echo "$proj" | jq -r '.number')"
    items="$(echo "$items" | jq \
      --arg type "github_project_v2" --arg name "$title" \
      --arg url "$url" --argjson n "$number" --arg ts "$ts" \
      '. + [{"type":$type,"name":$name,"source_url":$url,"source_number":$n,
             "status":"inventory","manual_action_required":true,
             "reason":"GitHub Projects cannot be created via API on free plan",
             "inventoried_at":$ts}]')"
  done < <(echo "$projects" | jq -c '.[]' 2>/dev/null || true)

  # ---- 2. Installed GitHub Apps — inventory only -------------------------
  log "Fetching installed GitHub Apps on $SOURCE_ORG..."
  local apps
  apps="$(ghsrc api "orgs/$SOURCE_ORG/installations" \
    2>/dev/null | jq -rs '.[0].installations // []' 2>/dev/null)" || apps='[]'

  local app_count
  app_count="$(echo "$apps" | jq 'length' 2>/dev/null || echo 0)"
  log "Found $app_count installed GitHub Apps"

  while IFS= read -r app; do
    local app_name app_id
    app_name="$(echo "$app" | jq -r '.app_slug // .app_id // "unknown"')"
    app_id="$(echo   "$app" | jq -r '.id')"
    items="$(echo "$items" | jq \
      --arg type "github_app" --arg name "$app_name" --argjson id "$app_id" --arg ts "$ts" \
      '. + [{"type":$type,"name":$name,"source_installation_id":$id,
             "status":"inventory","manual_action_required":true,
             "reason":"GitHub App installations must be authorized by the app owner",
             "inventoried_at":$ts}]')"
  done < <(echo "$apps" | jq -c '.[]' 2>/dev/null || true)

  # ---- 3. Org-level webhooks ---------------------------------------------
  # full: create in target now. export: record config; import will create later.
  log "Fetching org webhooks from $SOURCE_ORG..."
  local org_webhooks
  org_webhooks="$(ghsrc api "orgs/$SOURCE_ORG/hooks" \
    2>/dev/null | jq -rs '.[0] // []' 2>/dev/null)" || org_webhooks='[]'

  local org_wh_count
  org_wh_count="$(echo "$org_webhooks" | jq 'length' 2>/dev/null || echo 0)"
  log "Found $org_wh_count org webhooks"

  while IFS= read -r hook; do
    local hook_name hook_url hook_ct hook_ssl hook_active hook_events hook_id
    hook_name="$(echo   "$hook" | jq -r '.name // "web"')"
    hook_url="$(echo    "$hook" | jq -r '.config.url // ""')"
    hook_ct="$(echo     "$hook" | jq -r '.config.content_type // "json"')"
    hook_ssl="$(echo    "$hook" | jq -r '.config.insecure_ssl // "0"')"
    hook_active="$(echo "$hook" | jq '.active // true')"
    hook_events="$(echo "$hook" | jq '.events // ["push"]')"
    hook_id="$(echo     "$hook" | jq -r '.id')"

    local status="exported"
    if in_full; then
      if dry_run_skip "create org webhook $hook_url in $TARGET_ORG (no secret)"; then
        status="created_no_secret"
      else
        status="$(_create_org_webhook "$hook_name" "$hook_url" "$hook_ct" "$hook_ssl" "$hook_active" "$hook_events")"
      fi
    fi

    items="$(echo "$items" | jq \
      --arg type   "org_webhook" --arg name "$hook_name" \
      --arg url    "$hook_url"   --argjson id "$hook_id" \
      --arg ct "$hook_ct" --arg ssl "$hook_ssl" \
      --argjson active "$hook_active" --argjson events "$hook_events" \
      --arg status "$status"     --arg ts "$ts" \
      '. + [{"type":$type,"name":$name,"source_id":$id,"config_url":$url,
             "config_content_type":$ct,"config_insecure_ssl":$ssl,
             "config_active":$active,"config_events":$events,
             "status":$status,"manual_action_required":true,
             "reason":"Webhook secret is write-only and must be set manually in target org",
             "inventoried_at":$ts}]')"
  done < <(echo "$org_webhooks" | jq -c '.[]' 2>/dev/null || true)

  # ---- 4. Wiki pages (per repo) — inventory only -------------------------
  log "Checking wikis across repos in $SOURCE_ORG..."
  while IFS= read -r repo; do
    local repo_name has_wiki
    repo_name="$(echo "$repo" | jq -r '.name')"
    has_wiki="$(echo  "$repo" | jq -r '.has_wiki // false')"
    if [[ "$has_wiki" == "true" ]]; then
      local wiki_url="https://github.com/$SOURCE_ORG/$repo_name.wiki.git"
      items="$(echo "$items" | jq \
        --arg type "wiki" --arg name "$repo_name wiki" \
        --arg url "$wiki_url" --arg ts "$ts" \
        '. + [{"type":$type,"name":$name,"source_url":$url,
               "status":"inventory","manual_action_required":true,
               "reason":"Wiki repos can be mirrored separately via: git clone <repo>.wiki.git",
               "inventoried_at":$ts}]')"
    fi
  done < <(echo "$repos" | jq -c '.[]' 2>/dev/null || true)

  # ---- 5. Repo-level webhooks --------------------------------------------
  log "Fetching per-repo webhooks from $SOURCE_ORG..."
  local repo_wh_total=0
  while IFS= read -r repo; do
    local repo_name
    repo_name="$(echo "$repo" | jq -r '.name')"

    local repo_hooks
    repo_hooks="$(ghsrc api "repos/$SOURCE_ORG/$repo_name/hooks?per_page=100" \
      2>/dev/null | jq -rs '.[0] // []' 2>/dev/null)" || repo_hooks='[]'

    local rh_count
    rh_count="$(echo "$repo_hooks" | jq 'length' 2>/dev/null || echo 0)"
    [[ "$rh_count" -eq 0 ]] && continue
    repo_wh_total=$((repo_wh_total + rh_count))

    while IFS= read -r hook; do
      local hook_url hook_ct hook_ssl hook_active hook_events hook_id
      hook_url="$(echo    "$hook" | jq -r '.config.url // ""')"
      hook_ct="$(echo     "$hook" | jq -r '.config.content_type // "json"')"
      hook_ssl="$(echo    "$hook" | jq -r '.config.insecure_ssl // "0"')"
      hook_active="$(echo "$hook" | jq '.active // true')"
      hook_events="$(echo "$hook" | jq '.events // ["push"]')"
      hook_id="$(echo     "$hook" | jq -r '.id')"

      local status="exported"
      if in_full; then
        if dry_run_skip "create repo webhook $hook_url in $TARGET_ORG/$repo_name (no secret)"; then
          status="created_no_secret"
        else
          status="$(_create_repo_webhook "$repo_name" "$hook_url" "$hook_ct" "$hook_ssl" "$hook_active" "$hook_events")"
        fi
        pause 0.2
      fi

      items="$(echo "$items" | jq \
        --arg type     "repo_webhook" \
        --arg repo     "$repo_name" \
        --arg url      "$hook_url" \
        --argjson id   "$hook_id" \
        --arg ct "$hook_ct" --arg ssl "$hook_ssl" \
        --argjson active "$hook_active" --argjson events "$hook_events" \
        --arg status   "$status" \
        --arg ts       "$ts" \
        '. + [{"type":$type,"repo":$repo,"source_id":$id,"config_url":$url,
               "config_content_type":$ct,"config_insecure_ssl":$ssl,
               "config_active":$active,"config_events":$events,
               "status":$status,"manual_action_required":true,
               "reason":"Webhook secret is write-only and must be set manually in target repo",
               "inventoried_at":$ts}]')"
    done < <(echo "$repo_hooks" | jq -c '.[]' 2>/dev/null || true)
    pause 0.3
  done < <(echo "$repos" | jq -c '.[]' 2>/dev/null || true)
  log "Processed $repo_wh_total repo webhooks"

  # ---- 6. Actions secret NAMES (org + repo + dependabot) — inventory -----
  log "Inventorying Actions secret names from $SOURCE_ORG..."
  local org_secrets
  org_secrets="$(ghsrc api "orgs/$SOURCE_ORG/actions/secrets?per_page=100" \
    --paginate 2>/dev/null | jq -rs '[.[] | select(type == "object") | select(has("secrets")) | .secrets[] | select(type == "object")]')" || org_secrets='[]'
  while IFS= read -r secret; do
    local sname svis
    sname="$(echo "$secret" | jq -r '.name')"
    svis="$(echo  "$secret" | jq -r '.visibility // "all"')"
    items="$(echo "$items" | jq \
      --arg type "actions_secret" --arg scope "org" \
      --arg name "$sname" --arg vis "$svis" --arg ts "$ts" \
      '. + [{"type":$type,"scope":$scope,"name":$name,"visibility":$vis,
             "status":"inventory","manual_action_required":true,
             "reason":"Secret values are write-only; must be recreated from external vault",
             "inventoried_at":$ts}]')"
  done < <(echo "$org_secrets" | jq -c '.[]' 2>/dev/null || true)

  while IFS= read -r repo; do
    local repo_name
    repo_name="$(echo "$repo" | jq -r '.name')"
    local repo_secrets
    repo_secrets="$(ghsrc api "repos/$SOURCE_ORG/$repo_name/actions/secrets?per_page=100" \
      --paginate 2>/dev/null | jq -rs '[.[] | select(type == "object") | select(has("secrets")) | .secrets[] | select(type == "object")]')" || repo_secrets='[]'
    while IFS= read -r secret; do
      local sname
      sname="$(echo "$secret" | jq -r '.name')"
      items="$(echo "$items" | jq \
        --arg type "actions_secret" --arg scope "repo" \
        --arg repo "$repo_name" --arg name "$sname" --arg ts "$ts" \
        '. + [{"type":$type,"scope":$scope,"repo":$repo,"name":$name,
               "status":"inventory","manual_action_required":true,
               "reason":"Secret values are write-only; must be recreated from external vault",
               "inventoried_at":$ts}]')"
    done < <(echo "$repo_secrets" | jq -c '.[]' 2>/dev/null || true)
    pause 0.2
  done < <(echo "$repos" | jq -c '.[]' 2>/dev/null || true)

  local dep_secrets
  dep_secrets="$(ghsrc api "orgs/$SOURCE_ORG/dependabot/secrets?per_page=100" \
    --paginate 2>/dev/null | jq -rs '[.[] | select(type == "object") | select(has("secrets")) | .secrets[] | select(type == "object")]')" || dep_secrets='[]'
  while IFS= read -r secret; do
    local sname svis
    sname="$(echo "$secret" | jq -r '.name')"
    svis="$(echo  "$secret" | jq -r '.visibility // "all"')"
    items="$(echo "$items" | jq \
      --arg type "dependabot_secret" --arg scope "org" \
      --arg name "$sname" --arg vis "$svis" --arg ts "$ts" \
      '. + [{"type":$type,"scope":$scope,"name":$name,"visibility":$vis,
             "status":"inventory","manual_action_required":true,
             "reason":"Secret values are write-only; must be recreated from external vault",
             "inventoried_at":$ts}]')"
  done < <(echo "$dep_secrets" | jq -c '.[]' 2>/dev/null || true)

  # ---- 7. Self-hosted runners (org-level) — inventory --------------------
  log "Inventorying self-hosted runners from $SOURCE_ORG..."
  local runners
  runners="$(ghsrc api "orgs/$SOURCE_ORG/actions/runners?per_page=100" \
    2>/dev/null | jq -rs '.[0].runners // []' 2>/dev/null)" || runners='[]'
  local runner_count
  runner_count="$(echo "$runners" | jq 'length' 2>/dev/null || echo 0)"
  log "Found $runner_count self-hosted runners"
  while IFS= read -r runner; do
    local rname ros rarch rstatus rlabels
    rname="$(echo    "$runner" | jq -r '.name')"
    ros="$(echo      "$runner" | jq -r '.os // "unknown"')"
    rarch="$(echo    "$runner" | jq -r '.architecture // "unknown"')"
    rstatus="$(echo  "$runner" | jq -r '.status // "unknown"')"
    rlabels="$(echo  "$runner" | jq '.labels // [] | [.[].name]')"
    items="$(echo "$items" | jq \
      --arg type "self_hosted_runner" --arg name "$rname" \
      --arg os "$ros" --arg arch "$rarch" --arg status "$rstatus" \
      --argjson labels "$rlabels" --arg ts "$ts" \
      '. + [{"type":$type,"name":$name,"os":$os,"architecture":$arch,
             "source_status":$status,"labels":$labels,
             "status":"inventory","manual_action_required":true,
             "reason":"Runner machines are external; registration tokens are ephemeral — must re-register manually",
             "inventoried_at":$ts}]')"
  done < <(echo "$runners" | jq -c '.[]' 2>/dev/null || true)

  # ---- 8. Deploy keys (per repo) — inventory with public key -------------
  log "Inventorying deploy keys across repos in $SOURCE_ORG..."
  local dk_total=0
  while IFS= read -r repo; do
    local repo_name
    repo_name="$(echo "$repo" | jq -r '.name')"
    local keys
    keys="$(ghsrc api "repos/$SOURCE_ORG/$repo_name/keys?per_page=100" \
      2>/dev/null | jq -rs '.[0] // []' 2>/dev/null)" || keys='[]'
    local key_count
    key_count="$(echo "$keys" | jq 'length' 2>/dev/null || echo 0)"
    [[ "$key_count" -eq 0 ]] && continue
    dk_total=$((dk_total + key_count))
    while IFS= read -r key; do
      local kid ktitle kkey kro
      kid="$(echo    "$key" | jq -r '.id')"
      ktitle="$(echo "$key" | jq -r '.title // "deploy key"')"
      kkey="$(echo   "$key" | jq -r '.key // ""')"
      kro="$(echo    "$key" | jq -r '.read_only // true')"
      items="$(echo "$items" | jq \
        --arg type "deploy_key" --arg repo "$repo_name" \
        --argjson source_id "$kid" --arg title "$ktitle" \
        --arg pub_key "$kkey" --argjson read_only "$kro" --arg ts "$ts" \
        '. + [{"type":$type,"repo":$repo,"source_id":$source_id,
               "title":$title,"public_key":$pub_key,"read_only":$read_only,
               "status":"inventory","manual_action_required":true,
               "reason":"Private key is unreadable via API; public key recorded for reference — create a new key pair if needed",
               "inventoried_at":$ts}]')"
    done < <(echo "$keys" | jq -c '.[]' 2>/dev/null || true)
    pause 0.2
  done < <(echo "$repos" | jq -c '.[]' 2>/dev/null || true)
  log "Inventoried $dk_total deploy keys"

  # ---- 9. Write state file -----------------------------------------------
  _write_state_items "$items"

  local item_count
  item_count="$(echo "$items" | jq 'length')"
  ok "Stage 09 complete (mode=$MIRROR_MODE) — $item_count items inventoried/created"
  log "Summary:"
  echo "$items" | jq -r 'group_by(.type) | .[] | "  \(.[0].type): \(length)"' >&2

  if [[ "$DRY_RUN" -eq 0 ]]; then
    commit_state "mirror: state after stage 09 (other-objects, mode=$MIRROR_MODE) [skip ci]"
  fi
}

# ---------------------------------------------------------------------------
# _write_state_items <items_json> — persist items + recompute stats.
_write_state_items() {
  local items="$1"
  local item_count
  item_count="$(echo "$items" | jq 'length')"
  local tmp
  tmp="$(mktemp)"
  jq --argjson items "$items" --argjson total "$item_count" \
    '.items = $items |
     .stats.total   = $total |
     .stats.synced  = ($items | map(select(.status == "created_no_secret")) | length) |
     .stats.pending = ($items | map(select(.status == "inventory" or .status == "exported")) | length) |
     .stats.failed  = ($items | map(select(.status == "failed")) | length)' \
    "$STATE_FILE" > "$tmp"
  mv "$tmp" "$STATE_FILE"
}

# ---------------------------------------------------------------------------
# _import_other_objects — read serialized items and create webhooks in target.
# Only org_webhook / repo_webhook items are actionable; all others are
# inventory-only and left untouched. NEVER contacts the source org.
_import_other_objects() {
  local items
  items="$(jq -c '.items // []' "$STATE_FILE" 2>/dev/null || echo '[]')"
  local total
  total="$(echo "$items" | jq 'length')"
  log "Importing webhooks from $total inventoried items..."

  local created=0 skipped=0 failed=0
  local updated_items="$items"

  while IFS= read -r item; do
    local itype
    itype="$(echo "$item" | jq -r '.type')"
    case "$itype" in
      org_webhook|repo_webhook) ;;
      *) continue ;;
    esac

    local url ct ssl active events status repo
    url="$(echo "$item" | jq -r '.config_url // ""')"
    ct="$(echo "$item" | jq -r '.config_content_type // "json"')"
    ssl="$(echo "$item" | jq -r '.config_insecure_ssl // "0"')"
    active="$(echo "$item" | jq '.config_active // true')"
    events="$(echo "$item" | jq '.config_events // ["push"]')"

    [[ -z "$url" ]] && { skipped=$((skipped + 1)); continue; }

    if dry_run_skip "create $itype $url in $TARGET_ORG"; then
      created=$((created + 1)); continue
    fi

    if [[ "$itype" == "org_webhook" ]]; then
      local name
      name="$(echo "$item" | jq -r '.name // "web"')"
      status="$(_create_org_webhook "$name" "$url" "$ct" "$ssl" "$active" "$events")"
    else
      repo="$(echo "$item" | jq -r '.repo')"
      status="$(_create_repo_webhook "$repo" "$url" "$ct" "$ssl" "$active" "$events")"
      pause 0.2
    fi

    [[ "$status" == "failed" ]] && failed=$((failed + 1)) || created=$((created + 1))

    # Update this item's status in the in-memory array (match by type+url[+repo]).
    updated_items="$(echo "$updated_items" | jq \
      --arg t "$itype" --arg u "$url" --arg st "$status" \
      '[.[] | if (.type == $t and .config_url == $u) then .status = $st else . end]')"
  done < <(echo "$items" | jq -c '.[]' 2>/dev/null || true)

  _write_state_items "$updated_items"
  ok "  [import] webhooks: created=$created skipped=$skipped failed=$failed"
}

main "$@"
