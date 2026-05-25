#!/usr/bin/env bash
# mirror/stages/08-other-objects.sh
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
# NOT included here (handled by dedicated stages):
#   - Releases + assets  → stage 10 (mirror-releases)
#   - Branch protections → stage 11 (mirror-branch-protections)
#   - Actions variables  → stage 12 (mirror-actions-variables)
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

  log "Stage 08 — other-objects starting"

  state_init "$STATE_FILE" "08-other-objects"

  local items="[]"
  local ts
  ts="$(now)"

  # Fetch all source repos once — reused by multiple sections below
  log "Fetching source repos from $SOURCE_ORG..."
  local repos
  repos="$(gh_paginate ghsrc "orgs/$SOURCE_ORG/repos")"

  # ---- 1. GitHub Projects (org-level) — inventory only -------------------
  log "Fetching GitHub Projects from $SOURCE_ORG..."
  local projects
  projects="$(ghsrc api graphql \
    -f query='query($org:String!){organization(login:$org){projectsV2(first:20){nodes{id title url number}}}}' \
    -f org="$SOURCE_ORG" \
    2>/dev/null | jq -rs '.[0].data.organization.projectsV2.nodes // []' 2>/dev/null || echo '[]')"

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
    2>/dev/null | jq -rs '.[0].installations // []' 2>/dev/null || echo '[]')"

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

  # ---- 3. Org-level webhooks — CREATE in target (without secret) ---------
  log "Fetching org webhooks from $SOURCE_ORG..."
  local org_webhooks
  org_webhooks="$(ghsrc api "orgs/$SOURCE_ORG/hooks" \
    2>/dev/null | jq -rs '.[0] // []' 2>/dev/null || echo '[]')"

  local org_wh_count
  org_wh_count="$(echo "$org_webhooks" | jq 'length' 2>/dev/null || echo 0)"
  log "Found $org_wh_count org webhooks — will create in target without secret"

  # BUG-05 fix: pre-fetch existing target org webhook URLs to avoid duplicates on re-run.
  local tgt_org_hook_urls
  tgt_org_hook_urls="$(gh api "orgs/$TARGET_ORG/hooks?per_page=100" \
    2>/dev/null | jq -rs '.[0] // [] | [.[].config.url // ""] | map(select(. != ""))' \
    2>/dev/null || echo '[]')"

  while IFS= read -r hook; do
    local hook_name hook_url hook_ct hook_ssl hook_active hook_events hook_id
    hook_name="$(echo   "$hook" | jq -r '.name // "web"')"
    hook_url="$(echo    "$hook" | jq -r '.config.url // ""')"
    hook_ct="$(echo     "$hook" | jq -r '.config.content_type // "json"')"
    hook_ssl="$(echo    "$hook" | jq -r '.config.insecure_ssl // "0"')"
    hook_active="$(echo "$hook" | jq -r '.active // true')"
    hook_events="$(echo "$hook" | jq '.events // ["push"]')"
    hook_id="$(echo     "$hook" | jq -r '.id')"

    local status="created_no_secret"
    if dry_run_skip "create org webhook $hook_url in $TARGET_ORG (no secret)"; then
      status="created_no_secret"
    else
      # Skip if webhook with same URL already exists in target
      local already_in_tgt
      already_in_tgt="$(echo "$tgt_org_hook_urls" | jq -r --arg u "$hook_url" \
        '.[] | select(. == $u)' 2>/dev/null || true)"
      if [[ -n "$already_in_tgt" ]]; then
        log "  Org webhook $hook_url already exists in target — skipping"
        status="created_no_secret"
      else
        local wh_payload
        wh_payload="$(jq -n \
          --arg name   "$hook_name" \
          --arg url    "$hook_url" \
          --arg ct     "$hook_ct" \
          --arg ssl    "$hook_ssl" \
          --argjson active "$hook_active" \
          --argjson events "$hook_events" \
          '{"name":$name,"config":{"url":$url,"content_type":$ct,"insecure_ssl":$ssl},"events":$events,"active":$active}')"

        local wh_result
        wh_result="$(gh api "orgs/$TARGET_ORG/hooks" \
          --method POST --input <(echo "$wh_payload") \
          2>/dev/null || echo 'FAILED')"

        if [[ "$wh_result" == "FAILED" ]]; then
          warn "  Failed to create org webhook $hook_url in $TARGET_ORG"
          status="failed"
        else
          ok "  Created org webhook: $hook_url (secret must be set manually)"
        fi
      fi
    fi

    items="$(echo "$items" | jq \
      --arg type   "org_webhook" --arg name "$hook_name" \
      --arg url    "$hook_url"   --argjson id "$hook_id" \
      --arg status "$status"     --arg ts "$ts" \
      '. + [{"type":$type,"name":$name,"source_id":$id,"config_url":$url,
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

  # ---- 5. Repo-level webhooks — CREATE in target (without secret) --------
  log "Fetching per-repo webhooks from $SOURCE_ORG..."
  local repo_wh_total=0

  while IFS= read -r repo; do
    local repo_name
    repo_name="$(echo "$repo" | jq -r '.name')"

    local repo_hooks
    repo_hooks="$(ghsrc api "repos/$SOURCE_ORG/$repo_name/hooks?per_page=100" \
      2>/dev/null | jq -rs '.[0] // []' 2>/dev/null || echo '[]')"

    local rh_count
    rh_count="$(echo "$repo_hooks" | jq 'length' 2>/dev/null || echo 0)"
    [[ "$rh_count" -eq 0 ]] && continue

    repo_wh_total=$((repo_wh_total + rh_count))

    # BUG-05 fix: pre-fetch existing target repo webhook URLs per repo.
    local tgt_repo_hook_urls
    tgt_repo_hook_urls="$(gh api "repos/$TARGET_ORG/$repo_name/hooks?per_page=100" \
      2>/dev/null | jq -rs '.[0] // [] | [.[].config.url // ""] | map(select(. != ""))' \
      2>/dev/null || echo '[]')"

    while IFS= read -r hook; do
      local hook_url hook_ct hook_ssl hook_active hook_events hook_id
      hook_url="$(echo    "$hook" | jq -r '.config.url // ""')"
      hook_ct="$(echo     "$hook" | jq -r '.config.content_type // "json"')"
      hook_ssl="$(echo    "$hook" | jq -r '.config.insecure_ssl // "0"')"
      hook_active="$(echo "$hook" | jq -r '.active // true')"
      hook_events="$(echo "$hook" | jq '.events // ["push"]')"
      hook_id="$(echo     "$hook" | jq -r '.id')"

      local status="created_no_secret"
      if dry_run_skip "create repo webhook $hook_url in $TARGET_ORG/$repo_name (no secret)"; then
        status="created_no_secret"
      else
        local already_in_tgt_repo
        already_in_tgt_repo="$(echo "$tgt_repo_hook_urls" | jq -r --arg u "$hook_url" \
          '.[] | select(. == $u)' 2>/dev/null || true)"
        if [[ -n "$already_in_tgt_repo" ]]; then
          log "  Repo webhook $hook_url already exists in $TARGET_ORG/$repo_name — skipping"
          status="created_no_secret"
        else
          local rh_payload
          rh_payload="$(jq -n \
            --arg url    "$hook_url" \
            --arg ct     "$hook_ct" \
            --arg ssl    "$hook_ssl" \
            --argjson active "$hook_active" \
            --argjson events "$hook_events" \
            '{"config":{"url":$url,"content_type":$ct,"insecure_ssl":$ssl},"events":$events,"active":$active}')"

          local rh_result
          rh_result="$(gh api "repos/$TARGET_ORG/$repo_name/hooks" \
            --method POST --input <(echo "$rh_payload") \
            2>/dev/null || echo 'FAILED')"

          if [[ "$rh_result" == "FAILED" ]]; then
            warn "  Failed to create repo webhook $hook_url in $TARGET_ORG/$repo_name"
            status="failed"
          else
            ok "  Created repo webhook for $repo_name: $hook_url"
          fi
        fi
      fi
      pause 0.2

      items="$(echo "$items" | jq \
        --arg type     "repo_webhook" \
        --arg repo     "$repo_name" \
        --arg url      "$hook_url" \
        --argjson id   "$hook_id" \
        --arg status   "$status" \
        --arg ts       "$ts" \
        '. + [{"type":$type,"repo":$repo,"source_id":$id,"config_url":$url,
               "status":$status,"manual_action_required":true,
               "reason":"Webhook secret is write-only and must be set manually in target repo",
               "inventoried_at":$ts}]')"
    done < <(echo "$repo_hooks" | jq -c '.[]' 2>/dev/null || true)
    pause 0.3
  done < <(echo "$repos" | jq -c '.[]' 2>/dev/null || true)

  log "Processed $repo_wh_total repo webhooks"

  # ---- 6. Actions secret NAMES (org + repo + dependabot) — inventory -----
  # Secret VALUES cannot be read via API (write-only). We record names so
  # operators know what secrets must be recreated in the target org.
  log "Inventorying Actions secret names from $SOURCE_ORG..."

  # Org-level Actions secrets
  # BUG-01 fix: jq -s 'add // [] | .secrets' does object-merge, keeping only the
  # last page's .secrets array.  Use map()+add to concatenate all pages' arrays.
  local org_secrets
  org_secrets="$(ghsrc api "orgs/$SOURCE_ORG/actions/secrets?per_page=100" \
    --paginate 2>/dev/null | jq -s 'map(.secrets // []) | add // []' || echo '[]')"

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

  # Per-repo Actions secrets
  while IFS= read -r repo; do
    local repo_name
    repo_name="$(echo "$repo" | jq -r '.name')"

    local repo_secrets
    repo_secrets="$(ghsrc api "repos/$SOURCE_ORG/$repo_name/actions/secrets?per_page=100" \
      --paginate 2>/dev/null | jq -s 'map(.secrets // []) | add // []' || echo '[]')"

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

  # Org-level Dependabot secrets
  local dep_secrets
  dep_secrets="$(ghsrc api "orgs/$SOURCE_ORG/dependabot/secrets?per_page=100" \
    --paginate 2>/dev/null | jq -s 'map(.secrets // []) | add // []' || echo '[]')"

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
    2>/dev/null | jq -rs '.[0].runners // []' 2>/dev/null || echo '[]')"

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
      2>/dev/null | jq -rs '.[0] // []' 2>/dev/null || echo '[]')"

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
  local item_count
  item_count="$(echo "$items" | jq 'length')"

  local tmp
  tmp="$(mktemp)"
  jq --argjson items "$items" \
     --argjson total "$item_count" \
    '.items = $items |
     .stats.total   = $total |
     .stats.synced  = ($items | map(select(.status == "created_no_secret")) | length) |
     .stats.pending = ($items | map(select(.status == "inventory")) | length) |
     .stats.failed  = ($items | map(select(.status == "failed")) | length)' \
    "$STATE_FILE" > "$tmp"
  mv "$tmp" "$STATE_FILE"

  ok "Stage 08 complete — $item_count items inventoried/created"
  log "Summary:"
  echo "$items" | jq -r 'group_by(.type) | .[] | "  \(.[0].type): \(length)"' >&2

  if [[ "$DRY_RUN" -eq 0 ]]; then
    commit_state "mirror: state after stage 08 (other-objects) [skip ci]"
  fi
}

main "$@"
