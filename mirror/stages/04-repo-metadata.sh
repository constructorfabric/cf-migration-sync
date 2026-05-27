#!/usr/bin/env bash
# mirror/stages/04-repo-metadata.sh
# Copy per-repo metadata: description, topics, labels, milestones.
# State file: state/repos/<repo-name>.yaml (one per repo)
#
# Usage:
#   SOURCE_ORG=cyberfabric TARGET_ORG=constructorfabric \
#   GH_TOKEN=xxx GH_TOKEN_SOURCE=xxx \
#   ./mirror/stages/04-repo-metadata.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

TARGET_ORG="${TARGET_ORG:-constructorfabric}"
STATE_DIR="$REPO_ROOT/state/repos"

# ---------------------------------------------------------------------------
main() {
  check_dry_run "$@"
  preflight

  log "Stage 04 — repo-metadata starting"
  mkdir -p "$STATE_DIR"

  # Fetch source repos
  log "Fetching source repos from $SOURCE_ORG..."
  local repos
  repos="$(gh_paginate ghsrc "orgs/$SOURCE_ORG/repos")"
  local total
  total="$(echo "$repos" | jq 'length')"
  log "Found $total repos in $SOURCE_ORG"

  # ---- Load excluded repos from config ------------------------------------
  local excluded_repos
  excluded_repos="$(jq -r '.stage_04_repo_metadata.exclude_repos[] // empty' \
    "$MIRROR_CONFIG" 2>/dev/null || true)"
  if [[ -n "$excluded_repos" ]]; then
    log "Excluded repos: $(echo "$excluded_repos" | tr '\n' ' ')"
  fi

  local processed=0

  while IFS= read -r repo; do
    local name
    name="$(echo "$repo" | jq -r '.name')"
    local description
    description="$(echo "$repo" | jq -r '.description // ""')"

    processed=$((processed + 1))
    if (( processed % 10 == 0 )); then
      log "Progress: $processed/$total repos processed..."
    fi

    # Check exclusion list from config
    if [[ -n "$excluded_repos" ]] && echo "$excluded_repos" | grep -qx "$name" 2>/dev/null; then
      log "[$processed/$total] Skipping excluded repo: $name"
      continue
    fi

    log "[$processed/$total] Processing metadata for $name..."

    local state_file="$STATE_DIR/$name.yaml"
    state_init "$state_file" "04-repo-metadata"

    # ---- Copy description -----------------------------------------------
    _copy_description "$name" "$description"

    # ---- Copy topics ----------------------------------------------------
    _copy_topics "$name"

    # ---- Copy labels ----------------------------------------------------
    _copy_labels "$name" "$state_file"

    # ---- Copy milestones ------------------------------------------------
    _copy_milestones "$name" "$state_file"

    # ---- Copy repo settings (PATCH /repos) ------------------------------
    _copy_repo_settings "$name" "$repo" "$state_file"

    # ---- Copy Pages settings --------------------------------------------
    _copy_pages_settings "$name" "$state_file"

    state_update_stats "$state_file"
    pause 0.3

  done < <(echo "$repos" | jq -c '.[]')

  log "Stage 04 complete — processed $processed repos"

  if [[ "$DRY_RUN" -eq 0 ]]; then
    commit_state "mirror: state after stage 04 (repo-metadata) [skip ci]"
  fi
}

# ---------------------------------------------------------------------------
_copy_description() {
  local repo_name="$1"
  local description="$2"

  if [[ -z "$description" ]]; then
    return 0
  fi

  if dry_run_skip "set description for $TARGET_ORG/$repo_name"; then
    return 0
  fi

  gh api "repos/$TARGET_ORG/$repo_name" \
    --method PATCH \
    -f description="$description" \
    2>/dev/null || warn "Failed to set description for $repo_name"

  pause 0.3
}

# ---------------------------------------------------------------------------
_copy_topics() {
  local repo_name="$1"

  local src_topics
  src_topics="$(ghsrc api "repos/$SOURCE_ORG/$repo_name/topics" \
    -H "Accept: application/vnd.github.mercy-preview+json" \
    2>/dev/null || echo '{"names":[]}')"

  # Guard against extra runner output appended to stdout (RC-3)
  local topics_json
  topics_json="$(echo "$src_topics" | jq -rs '.[0].names // []' 2>/dev/null || echo '[]')"
  local topics_count
  topics_count="$(echo "$topics_json" | jq 'length')"

  if [[ "$topics_count" -eq 0 ]]; then
    return 0
  fi

  if dry_run_skip "set $topics_count topics for $TARGET_ORG/$repo_name"; then
    return 0
  fi

  # BUG-07 fix: use the cleaned topics_json (RC-3 guarded), not the raw src_topics.
  # Raw src_topics may contain extra non-JSON output appended by the runner.
  gh api "repos/$TARGET_ORG/$repo_name/topics" \
    --method PUT \
    -H "Accept: application/vnd.github.mercy-preview+json" \
    --input <(jq -n --argjson names "$topics_json" '{"names":$names}') \
    2>/dev/null || warn "Failed to set topics for $repo_name"

  pause 0.3
}

# ---------------------------------------------------------------------------
_copy_labels() {
  local repo_name="$1"
  local state_file="$2"

  log "  Syncing labels for $repo_name..."

  # Fetch source labels
  local src_labels
  src_labels="$(gh_paginate ghsrc "repos/$SOURCE_ORG/$repo_name/labels")"
  local label_count
  label_count="$(echo "$src_labels" | jq 'length')"
  log "  Found $label_count source labels"

  if [[ "$label_count" -eq 0 ]]; then
    return 0
  fi

  # Fetch existing target labels (for upsert logic)
  local tgt_labels
  tgt_labels="$(gh_paginate gh "repos/$TARGET_ORG/$repo_name/labels" 2>/dev/null)" || tgt_labels='[]'

  local ts
  ts="$(now)"

  while IFS= read -r label; do
    local lname
    lname="$(echo "$label" | jq -r '.name')"
    local lcolor
    lcolor="$(echo "$label" | jq -r '.color')"
    local ldesc
    ldesc="$(echo "$label" | jq -r '.description // ""')"

    # Check if label exists in target
    local existing_label
    existing_label="$(echo "$tgt_labels" | jq -r --arg n "$lname" \
      '.[] | select(.name == $n) | .name' 2>/dev/null || true)"

    local status="synced"

    if dry_run_skip "upsert label '$lname' in $TARGET_ORG/$repo_name"; then
      status="synced"
    elif [[ -n "$existing_label" ]]; then
      # Update existing label
      # BUG-08 fix: pass label name as argv[1] to avoid shell injection when lname
      # contains single quotes or backslashes; jq @uri as fallback if python3 absent.
      local encoded_name
      encoded_name="$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" \
        "$lname" 2>/dev/null || \
        printf '%s' "$lname" | jq -Rr '@uri' 2>/dev/null || \
        echo "$lname" | sed 's/ /%20/g; s/#/%23/g; s/&/%26/g')"
      gh api "repos/$TARGET_ORG/$repo_name/labels/$encoded_name" \
        --method PATCH \
        -f name="$lname" \
        -f color="$lcolor" \
        -f description="$ldesc" \
        2>/dev/null || { warn "Failed to update label '$lname' in $repo_name"; status="failed"; }
      pause 0.3
    else
      # Create new label
      gh api "repos/$TARGET_ORG/$repo_name/labels" \
        --method POST \
        -f name="$lname" \
        -f color="$lcolor" \
        -f description="$ldesc" \
        2>/dev/null || { warn "Failed to create label '$lname' in $repo_name"; status="failed"; }
      pause 0.3
    fi

    # Upsert into state items (labels section)
    local record
    record="$(jq -n \
      --arg name  "$lname" \
      --arg color "#$lcolor" \
      --arg desc  "$ldesc" \
      --arg st    "$status" \
      --arg ts    "$ts" \
      '{"type":"label","name":$name,"color":$color,"description":$desc,"status":$st,"synced_at":$ts}')"

    local tmp
    tmp="$(mktemp)"
    jq --arg name "$lname" --argjson rec "$record" \
      'if (.items | map(select(.type=="label" and .name==$name)) | length) > 0
       then .items = [.items[] | if (.type=="label" and .name==$name) then $rec else . end]
       else .items += [$rec]
       end' \
      "$state_file" > "$tmp"
    mv "$tmp" "$state_file"

  done < <(echo "$src_labels" | jq -c '.[]')

  ok "  Labels synced for $repo_name"
}

# ---------------------------------------------------------------------------
_copy_milestones() {
  local repo_name="$1"
  local state_file="$2"

  log "  Syncing milestones for $repo_name..."

  # Fetch source milestones (open + closed)
  local src_open src_closed src_milestones
  src_open="$(gh_paginate ghsrc "repos/$SOURCE_ORG/$repo_name/milestones" \
    2>/dev/null)" || src_open='[]'
  src_closed="$(ghsrc api "repos/$SOURCE_ORG/$repo_name/milestones?state=closed&per_page=100" \
    2>/dev/null)" || src_closed='[]'
  # BUG-13 fix: dedup by id — a milestone crossing open→closed between API calls
  # would appear in both arrays; unique_by(.id) collapses duplicates.
  src_milestones="$(printf '%s\n' "$src_open" "$src_closed" | jq -rs '[.[] | select(type == "array") | .[] | select(type == "object")] | unique_by(.id)')"

  local ms_count
  ms_count="$(echo "$src_milestones" | jq 'length')"

  if [[ "$ms_count" -eq 0 ]]; then
    return 0
  fi

  log "  Found $ms_count source milestones"

  # Fetch existing target milestones
  local tgt_open tgt_closed tgt_milestones
  tgt_open="$(gh_paginate gh "repos/$TARGET_ORG/$repo_name/milestones" \
    2>/dev/null)" || tgt_open='[]'
  tgt_closed="$(gh api "repos/$TARGET_ORG/$repo_name/milestones?state=closed&per_page=100" \
    2>/dev/null)" || tgt_closed='[]'
  tgt_milestones="$(printf '%s\n' "$tgt_open" "$tgt_closed" | jq -rs '[.[] | select(type == "array") | .[] | select(type == "object")]')"

  local ts
  ts="$(now)"

  while IFS= read -r ms; do
    local title
    title="$(echo "$ms" | jq -r '.title')"
    local desc
    desc="$(echo "$ms" | jq -r '.description // ""')"
    local ms_state
    ms_state="$(echo "$ms" | jq -r '.state // "open"')"
    local due_on
    due_on="$(echo "$ms" | jq -r '.due_on // ""')"

    # Check if milestone exists in target (match by title)
    local existing_number
    existing_number="$(echo "$tgt_milestones" | jq -r --arg t "$title" \
      '.[] | select(.title == $t) | .number' 2>/dev/null | head -1 || true)"

    local status="synced"

    if dry_run_skip "upsert milestone '$title' in $TARGET_ORG/$repo_name"; then
      status="synced"
    elif [[ -n "$existing_number" ]]; then
      # Update
      local payload
      payload="$(jq -n \
        --arg title "$title" \
        --arg state "$ms_state" \
        --arg desc  "$desc" \
        '{"title":$title,"state":$state,"description":$desc}')"

      if [[ -n "$due_on" && "$due_on" != "null" ]]; then
        payload="$(echo "$payload" | jq --arg due "$due_on" '.due_on = $due')"
      fi

      gh api "repos/$TARGET_ORG/$repo_name/milestones/$existing_number" \
        --method PATCH \
        --input <(echo "$payload") \
        2>/dev/null || { warn "Failed to update milestone '$title' in $repo_name"; status="failed"; }
      pause 0.3
    else
      # Create
      local payload
      payload="$(jq -n \
        --arg title "$title" \
        --arg state "$ms_state" \
        --arg desc  "$desc" \
        '{"title":$title,"state":$state,"description":$desc}')"

      if [[ -n "$due_on" && "$due_on" != "null" ]]; then
        payload="$(echo "$payload" | jq --arg due "$due_on" '.due_on = $due')"
      fi

      gh api "repos/$TARGET_ORG/$repo_name/milestones" \
        --method POST \
        --input <(echo "$payload") \
        2>/dev/null || { warn "Failed to create milestone '$title' in $repo_name"; status="failed"; }
      pause 0.3
    fi

    # Upsert into state
    local record
    record="$(jq -n \
      --arg title  "$title" \
      --arg state  "$ms_state" \
      --arg st     "$status" \
      --arg ts     "$ts" \
      '{"type":"milestone","title":$title,"state":$state,"status":$st,"synced_at":$ts}')"

    local tmp
    tmp="$(mktemp)"
    jq --arg title "$title" --argjson rec "$record" \
      'if (.items | map(select(.type=="milestone" and .title==$title)) | length) > 0
       then .items = [.items[] | if (.type=="milestone" and .title==$title) then $rec else . end]
       else .items += [$rec]
       end' \
      "$state_file" > "$tmp"
    mv "$tmp" "$state_file"

  done < <(echo "$src_milestones" | jq -c '.[]')

  ok "  Milestones synced for $repo_name"
}

# ---------------------------------------------------------------------------
# _copy_repo_settings — sync PATCH /repos/{owner}/{repo} settings
#
# Settings table: "api_field  type"
#   string → -f (JSON string)
#   bool   → -F (type-inferred; "true"/"false" → JSON booleans)
#
# Ordering rules enforced below:
#   1. Regular settings (any order)
#   2. default_branch — after git mirror so branch already exists
#   3. archived=true LAST — makes repo read-only; further PATCH calls fail
#
# Not synced intentionally:
#   name       — would rename the repo
#   visibility — risky; handled by --bare clone matching source privacy
# ---------------------------------------------------------------------------
_copy_repo_settings() {
  local repo_name="$1"
  local src_repo="$2"    # full source repo JSON object
  local state_file="$3"

  log "  Syncing repo settings for $repo_name..."

  local REPO_SETTINGS=(
    "has_issues                  bool"
    "has_projects                bool"
    "has_wiki                    bool"
    "allow_merge_commit          bool"
    "allow_squash_merge          bool"
    "allow_rebase_merge          bool"
    "allow_auto_merge            bool"
    "delete_branch_on_merge      bool"
    "allow_forking               bool"
    "web_commit_signoff_required bool"
    "homepage                    string"
    # -- Merge strategy titles/messages (controls default commit message style) --
    "allow_update_branch           bool"
    "squash_merge_commit_title     string"
    "squash_merge_commit_message   string"
    "merge_commit_title            string"
    "merge_commit_message          string"
  )

  local ts
  ts="$(now)"

  for setting_def in "${REPO_SETTINGS[@]}"; do
    local field type
    field="$(echo "$setting_def" | awk '{print $1}')"
    type="$(echo  "$setting_def" | awk '{print $2}')"

    local src_val
    src_val="$(echo "$src_repo" | jq -r --arg f "$field" \
      'if .[$f] != null then .[$f] | tostring else empty end' \
      2>/dev/null || true)"

    [[ -z "$src_val" ]] && continue

    if dry_run_skip "PATCH repos/$TARGET_ORG/$repo_name $field=$src_val"; then
      _upsert_repo_setting "$state_file" "$field" "$src_val" "synced" "$ts"
      continue
    fi

    local result
    if [[ "$type" == "bool" ]]; then
      result="$(gh api "repos/$TARGET_ORG/$repo_name" \
        --method PATCH -F "$field=$src_val" 2>/dev/null)" || result='FAILED'
    else
      result="$(gh api "repos/$TARGET_ORG/$repo_name" \
        --method PATCH -f "$field=$src_val" 2>/dev/null)" || result='FAILED'
    fi

    if [[ "$result" == "FAILED" ]]; then
      warn "  Failed to set $field=$src_val for $repo_name"
      _upsert_repo_setting "$state_file" "$field" "$src_val" "failed" "$ts"
    else
      ok "  Set $field=$src_val for $repo_name"
      _upsert_repo_setting "$state_file" "$field" "$src_val" "synced" "$ts"
    fi
    pause 0.2
  done

  # -- default_branch: after git mirror so the branch already exists in target --
  local src_default_branch
  src_default_branch="$(echo "$src_repo" | jq -r '.default_branch // empty' 2>/dev/null || true)"
  if [[ -n "$src_default_branch" ]]; then
    if dry_run_skip "PATCH repos/$TARGET_ORG/$repo_name default_branch=$src_default_branch"; then
      _upsert_repo_setting "$state_file" "default_branch" "$src_default_branch" "synced" "$ts"
    else
      local result
      result="$(gh api "repos/$TARGET_ORG/$repo_name" \
        --method PATCH -f "default_branch=$src_default_branch" \
        2>/dev/null)" || result='FAILED'
      if [[ "$result" == "FAILED" ]]; then
        warn "  Failed to set default_branch=$src_default_branch for $repo_name"
        _upsert_repo_setting "$state_file" "default_branch" "$src_default_branch" "failed" "$ts"
      else
        ok "  Set default_branch=$src_default_branch for $repo_name"
        _upsert_repo_setting "$state_file" "default_branch" "$src_default_branch" "synced" "$ts"
      fi
      pause 0.2
    fi
  fi

  # -- archived: MUST be set last — archiving makes the repo read-only --
  local archived
  archived="$(echo "$src_repo" | jq -r '.archived // "false"' 2>/dev/null || echo 'false')"
  if [[ "$archived" == "true" ]]; then
    if dry_run_skip "PATCH repos/$TARGET_ORG/$repo_name archived=true"; then
      _upsert_repo_setting "$state_file" "archived" "true" "synced" "$ts"
    else
      local result
      result="$(gh api "repos/$TARGET_ORG/$repo_name" \
        --method PATCH -F "archived=true" 2>/dev/null)" || result='FAILED'
      if [[ "$result" == "FAILED" ]]; then
        warn "  Failed to archive $repo_name"
        _upsert_repo_setting "$state_file" "archived" "true" "failed" "$ts"
      else
        ok "  Archived $repo_name (source is archived)"
        _upsert_repo_setting "$state_file" "archived" "true" "synced" "$ts"
      fi
    fi
  fi

  ok "  Repo settings synced for $repo_name"
}

# ---------------------------------------------------------------------------
_upsert_repo_setting() {
  local state_file="$1"
  local field="$2"
  local value="$3"
  local status="$4"
  local ts="$5"

  local record
  record="$(jq -n \
    --arg type   "repo_setting" \
    --arg name   "$field" \
    --arg value  "$value" \
    --arg status "$status" \
    --arg ts     "$ts" \
    '{"type":$type,"name":$name,"value":$value,"status":$status,"synced_at":$ts}')"

  local tmp
  tmp="$(mktemp)"
  jq --arg field "$field" --argjson rec "$record" \
    'if (.items | map(select(.type=="repo_setting" and .name==$field)) | length) > 0
     then .items = [.items[] | if (.type=="repo_setting" and .name==$field) then $rec else . end]
     else .items += [$rec]
     end' \
    "$state_file" > "$tmp"
  mv "$tmp" "$state_file"
}

# ---------------------------------------------------------------------------
# _copy_pages_settings — mirror GitHub Pages configuration for a repo.
#
# Pages are only mirrored when already enabled on the source repo.
# Disabling Pages on a repo is not done here — the target either has Pages
# or it doesn't; enabling it requires the source branch/path to exist.
#
# Limitations:
#   - custom_domain: deliberately not copied (DNS must be reconfigured manually)
#   - https_enforced: only applicable once a custom domain is set; skipped
# ---------------------------------------------------------------------------
_copy_pages_settings() {
  local repo_name="$1"
  local state_file="$2"

  # Fetch source Pages config — 404 means Pages are not enabled (not an error)
  local src_pages
  src_pages="$(ghsrc api "repos/$SOURCE_ORG/$repo_name/pages" \
    2>/dev/null | jq -rs '.[0] // empty' 2>/dev/null || true)"

  if [[ -z "$src_pages" ]]; then
    return 0  # Pages not enabled on source
  fi

  local src_source_branch src_source_path src_build_type
  src_source_branch="$(echo "$src_pages" | jq -r '.source.branch // "main"')"
  src_source_path="$(echo   "$src_pages" | jq -r '.source.path   // "/"')"
  src_build_type="$(echo    "$src_pages" | jq -r '.build_type    // "legacy"')"

  log "  Syncing Pages settings for $repo_name (branch=$src_source_branch path=$src_source_path build=$src_build_type)..."

  # Check whether Pages is already enabled on target
  local tgt_pages
  tgt_pages="$(gh api "repos/$TARGET_ORG/$repo_name/pages" \
    2>/dev/null | jq -rs '.[0] // empty' 2>/dev/null || true)"

  local ts
  ts="$(now)"

  if dry_run_skip "configure Pages for $TARGET_ORG/$repo_name (branch=$src_source_branch)"; then
    _upsert_repo_setting "$state_file" "pages_source_branch" "$src_source_branch" "synced" "$ts"
    return 0
  fi

  local status="synced"

  if [[ -z "$tgt_pages" ]]; then
    # Enable Pages on target
    local create_payload
    create_payload="$(jq -n \
      --arg branch "$src_source_branch" \
      --arg path   "$src_source_path" \
      --arg build  "$src_build_type" \
      '{"source":{"branch":$branch,"path":$path},"build_type":$build}')"

    local create_result
    create_result="$(gh api "repos/$TARGET_ORG/$repo_name/pages" \
      --method POST \
      --input <(echo "$create_payload") \
      2>/dev/null)" || create_result='FAILED'

    if [[ "$create_result" == "FAILED" ]]; then
      warn "  Failed to enable Pages for $repo_name (branch '$src_source_branch' may not exist yet)"
      status="failed"
    else
      ok "  Enabled Pages for $repo_name"
    fi
  else
    # Update existing Pages config
    local update_payload
    update_payload="$(jq -n \
      --arg branch "$src_source_branch" \
      --arg path   "$src_source_path" \
      --arg build  "$src_build_type" \
      '{"source":{"branch":$branch,"path":$path},"build_type":$build}')"

    local update_result
    update_result="$(gh api "repos/$TARGET_ORG/$repo_name/pages" \
      --method PUT \
      --input <(echo "$update_payload") \
      2>/dev/null)" || update_result='FAILED'

    if [[ "$update_result" == "FAILED" ]]; then
      warn "  Failed to update Pages settings for $repo_name"
      status="failed"
    else
      ok "  Updated Pages settings for $repo_name"
    fi
  fi

  _upsert_repo_setting "$state_file" "pages_source_branch" "$src_source_branch" "$status" "$ts"
  _upsert_repo_setting "$state_file" "pages_source_path"   "$src_source_path"   "$status" "$ts"
  _upsert_repo_setting "$state_file" "pages_build_type"    "$src_build_type"    "$status" "$ts"
}

main "$@"
