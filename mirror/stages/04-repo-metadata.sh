#!/usr/bin/env bash
# mirror/stages/04-repo-metadata.sh
# Copy per-repo metadata: description, topics, labels, milestones, settings, Pages.
# State file: state/repos/<repo-name>.yaml (one per repo)
#
# Modes (MIRROR_MODE):
#   full   — fetch each repo's source metadata and apply to target (default).
#   export — fetch each repo's source metadata into a per-repo snapshot in state
#            (.source_snapshot). NEVER contacts the target org.
#   import — read the per-repo snapshot from state and apply to target.
#            NEVER contacts the source org.
#
# The source reads (topics, labels, milestones, Pages) are centralised into
# _build_source_snapshot; the _apply_* helpers only write to the target and take
# their source data as arguments, so full and import share identical apply code.
#
# Usage:
#   SOURCE_ORG=cyberfabric TARGET_ORG=constructorfabric \
#   GH_TOKEN=xxx GH_TOKEN_SOURCE=xxx \
#   MIRROR_MODE=full|export|import \
#   ./mirror/stages/04-repo-metadata.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

TARGET_ORG="${TARGET_ORG:-}"   # required; validated in preflight (no hardcoded default)
STATE_DIR="$REPO_ROOT/state/repos"

# ---------------------------------------------------------------------------
main() {
  check_dry_run "$@"
  preflight

  log "Stage 04 — repo-metadata starting (mode=$MIRROR_MODE)"
  mkdir -p "$STATE_DIR"

  local excluded_repos
  excluded_repos="$(jq -r '.stage_04_repo_metadata.exclude_repos[] // empty' \
    "$MIRROR_CONFIG" 2>/dev/null || true)"
  [[ -n "$excluded_repos" ]] && log "Excluded repos: $(echo "$excluded_repos" | tr '\n' ' ')"

  if in_import; then
    _run_import "$excluded_repos"
  else
    _run_source "$excluded_repos"   # full + export
  fi

  log "Stage 04 complete"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    commit_state "mirror: state after stage 04 (repo-metadata, mode=$MIRROR_MODE) [skip ci]"
  fi
}

# ---------------------------------------------------------------------------
# _run_source — full + export: enumerate source repos, build a snapshot per repo.
# In export mode, store the snapshot and stop. In full mode, apply immediately.
_run_source() {
  local excluded_repos="$1"

  log "Fetching source repos from $SOURCE_ORG..."
  local repos total
  repos="$(gh_paginate ghsrc "orgs/$SOURCE_ORG/repos")"
  total="$(echo "$repos" | jq 'length')"
  log "Found $total repos in $SOURCE_ORG"

  local processed=0
  while IFS= read -r repo; do
    local name
    name="$(echo "$repo" | jq -r '.name')"

    processed=$((processed + 1))
    (( processed % 10 == 0 )) && log "Progress: $processed/$total repos processed..."

    if [[ -n "$excluded_repos" ]] && echo "$excluded_repos" | grep -qx "$name" 2>/dev/null; then
      log "[$processed/$total] Skipping excluded repo: $name"
      continue
    fi

    log "[$processed/$total] Processing metadata for $name..."
    local state_file="$STATE_DIR/$name.yaml"
    state_init "$state_file" "04-repo-metadata"

    local snapshot
    snapshot="$(_build_source_snapshot "$name" "$repo")"

    if in_export; then
      local _tmp
      _tmp="$(mktemp)"
      jq --argjson snap "$snapshot" --arg ts "$(now)" \
        '.source_snapshot = $snap | .exported_at = $ts' "$state_file" > "$_tmp" && mv "$_tmp" "$state_file"
      ok "  [export] Snapshot stored for $name"
    else
      _apply_snapshot "$name" "$snapshot" "$state_file"
      state_update_stats "$state_file"
    fi
    pause 0.3
  done < <(echo "$repos" | jq -c '.[]')

  log "Processed $processed repos"
}

# ---------------------------------------------------------------------------
# _run_import — read each per-repo snapshot from state and apply to target.
_run_import() {
  local excluded_repos="$1"
  shopt -s nullglob
  local files=( "$STATE_DIR"/*.yaml )
  shopt -u nullglob
  if [[ ${#files[@]} -eq 0 ]]; then
    warn "No state files in $STATE_DIR — run MIRROR_MODE=export first"
    return 0
  fi

  local processed=0
  local f
  for f in "${files[@]}"; do
    local name
    name="$(basename "$f" .yaml)"
    processed=$((processed + 1))

    if [[ -n "$excluded_repos" ]] && echo "$excluded_repos" | grep -qx "$name" 2>/dev/null; then
      log "Skipping excluded repo: $name"
      continue
    fi

    local snapshot
    snapshot="$(jq -c '.source_snapshot // empty' "$f" 2>/dev/null || true)"
    if [[ -z "$snapshot" ]]; then
      warn "  No source_snapshot in $f — run export first; skipping $name"
      continue
    fi
    log "Importing metadata for $name..."
    _apply_snapshot "$name" "$snapshot" "$f"
    state_update_stats "$f"
    pause 0.3
  done
  log "Processed $processed repos"
}

# ---------------------------------------------------------------------------
# _build_source_snapshot <repo> <repo_json> — fetch all source metadata for one
# repo and emit a JSON snapshot on stdout. SOURCE reads only.
_build_source_snapshot() {
  local repo_name="$1" repo_json="$2"

  local description
  description="$(echo "$repo_json" | jq -r '.description // ""')"

  # Topics
  local src_topics topics_json
  src_topics="$(ghsrc api "repos/$SOURCE_ORG/$repo_name/topics" \
    -H "Accept: application/vnd.github.mercy-preview+json" 2>/dev/null || echo '{"names":[]}')"
  topics_json="$(echo "$src_topics" | jq -rs '.[0].names // []' 2>/dev/null || echo '[]')"

  # Labels
  local labels_json
  labels_json="$(gh_paginate ghsrc "repos/$SOURCE_ORG/$repo_name/labels")" || labels_json='[]'

  # Milestones (open + closed, deduped by id)
  local ms_open ms_closed milestones_json
  ms_open="$(gh_paginate ghsrc "repos/$SOURCE_ORG/$repo_name/milestones" 2>/dev/null)" || ms_open='[]'
  ms_closed="$(ghsrc api "repos/$SOURCE_ORG/$repo_name/milestones?state=closed&per_page=100" 2>/dev/null)" || ms_closed='[]'
  milestones_json="$(printf '%s\n' "$ms_open" "$ms_closed" | \
    jq -rs '[.[] | select(type == "array") | .[] | select(type == "object")] | unique_by(.id)')"

  # Pages (null when not enabled)
  local src_pages pages_json
  src_pages="$(ghsrc api "repos/$SOURCE_ORG/$repo_name/pages" 2>/dev/null)" || src_pages=""
  if [[ -z "$src_pages" ]]; then
    pages_json='null'
  else
    pages_json="$(echo "$src_pages" | jq -rs '.[0] // null' 2>/dev/null || echo 'null')"
  fi

  jq -n \
    --arg desc "$description" \
    --argjson repo "$repo_json" \
    --argjson topics "$topics_json" \
    --argjson labels "$labels_json" \
    --argjson milestones "$milestones_json" \
    --argjson pages "$pages_json" \
    '{description:$desc, repo:$repo, topics:$topics, labels:$labels,
      milestones:$milestones, pages:$pages}'
}

# ---------------------------------------------------------------------------
# _apply_snapshot <repo> <snapshot_json> <state_file> — apply a source snapshot
# to the target. TARGET writes only; no source access. Shared by full + import.
_apply_snapshot() {
  local repo_name="$1" snapshot="$2" state_file="$3"

  local description repo_json topics_json labels_json milestones_json pages_json
  description="$(echo "$snapshot" | jq -r '.description // ""')"
  repo_json="$(echo "$snapshot" | jq -c '.repo // {}')"
  topics_json="$(echo "$snapshot" | jq -c '.topics // []')"
  labels_json="$(echo "$snapshot" | jq -c '.labels // []')"
  milestones_json="$(echo "$snapshot" | jq -c '.milestones // []')"
  pages_json="$(echo "$snapshot" | jq -c '.pages // null')"

  _apply_description  "$repo_name" "$description"
  _apply_topics       "$repo_name" "$topics_json"
  _apply_labels       "$repo_name" "$state_file" "$labels_json"
  _apply_milestones   "$repo_name" "$state_file" "$milestones_json"
  _apply_repo_settings "$repo_name" "$repo_json" "$state_file"
  _apply_pages         "$repo_name" "$state_file" "$pages_json"
}

# ---------------------------------------------------------------------------
_apply_description() {
  local repo_name="$1" description="$2"
  [[ -z "$description" ]] && return 0
  if dry_run_skip "set description for $TARGET_ORG/$repo_name"; then return 0; fi
  gh api "repos/$TARGET_ORG/$repo_name" \
    --method PATCH -f description="$description" \
    2>/dev/null || warn "Failed to set description for $repo_name"
  pause 0.3
}

# ---------------------------------------------------------------------------
_apply_topics() {
  local repo_name="$1" topics_json="$2"
  local topics_count
  topics_count="$(echo "$topics_json" | jq 'length')"
  [[ "$topics_count" -eq 0 ]] && return 0
  if dry_run_skip "set $topics_count topics for $TARGET_ORG/$repo_name"; then return 0; fi

  local _tmp
  _tmp="$(mktemp)"
  jq -n --argjson names "$topics_json" '{"names":$names}' > "$_tmp"
  gh api "repos/$TARGET_ORG/$repo_name/topics" \
    --method PUT \
    -H "Accept: application/vnd.github.mercy-preview+json" \
    --input "$_tmp" \
    2>/dev/null || warn "Failed to set topics for $repo_name"
  rm -f "$_tmp"
  pause 0.3
}

# ---------------------------------------------------------------------------
_apply_labels() {
  local repo_name="$1" state_file="$2" src_labels="$3"

  log "  Syncing labels for $repo_name..."
  local label_count
  label_count="$(echo "$src_labels" | jq 'length')"
  log "  Found $label_count source labels"
  [[ "$label_count" -eq 0 ]] && return 0

  local tgt_labels
  tgt_labels="$(gh_paginate gh "repos/$TARGET_ORG/$repo_name/labels" 2>/dev/null)" || tgt_labels='[]'

  local ts
  ts="$(now)"

  while IFS= read -r label; do
    local lname lcolor ldesc
    lname="$(echo "$label" | jq -r '.name')"
    lcolor="$(echo "$label" | jq -r '.color')"
    ldesc="$(echo "$label" | jq -r '.description // ""')"

    local existing_label
    existing_label="$(echo "$tgt_labels" | jq -r --arg n "$lname" \
      '.[] | select(.name == $n) | .name' 2>/dev/null || true)"

    local status="synced"

    if dry_run_skip "upsert label '$lname' in $TARGET_ORG/$repo_name"; then
      status="synced"
    elif [[ -n "$existing_label" ]]; then
      local encoded_name
      encoded_name="$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" \
        "$lname" 2>/dev/null || \
        printf '%s' "$lname" | jq -Rr '@uri' 2>/dev/null || \
        echo "$lname" | sed 's/ /%20/g; s/#/%23/g; s/&/%26/g')"
      gh api "repos/$TARGET_ORG/$repo_name/labels/$encoded_name" \
        --method PATCH \
        -f name="$lname" -f color="$lcolor" -f description="$ldesc" \
        2>/dev/null || { warn "Failed to update label '$lname' in $repo_name"; status="failed"; }
      pause 0.3
    else
      gh api "repos/$TARGET_ORG/$repo_name/labels" \
        --method POST \
        -f name="$lname" -f color="$lcolor" -f description="$ldesc" \
        2>/dev/null || { warn "Failed to create label '$lname' in $repo_name"; status="failed"; }
      pause 0.3
    fi

    local record
    record="$(jq -n \
      --arg name "$lname" --arg color "#$lcolor" --arg desc "$ldesc" \
      --arg st "$status" --arg ts "$ts" \
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
_apply_milestones() {
  local repo_name="$1" state_file="$2" src_milestones="$3"

  log "  Syncing milestones for $repo_name..."
  local ms_count
  ms_count="$(echo "$src_milestones" | jq 'length')"
  [[ "$ms_count" -eq 0 ]] && return 0
  log "  Found $ms_count source milestones"

  local tgt_open tgt_closed tgt_milestones
  tgt_open="$(gh_paginate gh "repos/$TARGET_ORG/$repo_name/milestones" 2>/dev/null)" || tgt_open='[]'
  tgt_closed="$(gh api "repos/$TARGET_ORG/$repo_name/milestones?state=closed&per_page=100" 2>/dev/null)" || tgt_closed='[]'
  tgt_milestones="$(printf '%s\n' "$tgt_open" "$tgt_closed" | jq -rs '[.[] | select(type == "array") | .[] | select(type == "object")]')"

  local ts
  ts="$(now)"

  while IFS= read -r ms; do
    local title desc ms_state due_on
    title="$(echo "$ms" | jq -r '.title')"
    desc="$(echo "$ms" | jq -r '.description // ""')"
    ms_state="$(echo "$ms" | jq -r '.state // "open"')"
    due_on="$(echo "$ms" | jq -r '.due_on // ""')"

    local existing_number
    existing_number="$(echo "$tgt_milestones" | jq -r --arg t "$title" \
      '.[] | select(.title == $t) | .number' 2>/dev/null | head -1 || true)"

    local status="synced"

    if dry_run_skip "upsert milestone '$title' in $TARGET_ORG/$repo_name"; then
      status="synced"
    else
      local payload _tmp
      payload="$(jq -n --arg title "$title" --arg state "$ms_state" --arg desc "$desc" \
        '{"title":$title,"state":$state,"description":$desc}')"
      if [[ -n "$due_on" && "$due_on" != "null" ]]; then
        payload="$(echo "$payload" | jq --arg due "$due_on" '.due_on = $due')"
      fi
      _tmp="$(mktemp)"
      printf '%s' "$payload" > "$_tmp"
      if [[ -n "$existing_number" ]]; then
        gh api "repos/$TARGET_ORG/$repo_name/milestones/$existing_number" \
          --method PATCH --input "$_tmp" \
          2>/dev/null || { warn "Failed to update milestone '$title' in $repo_name"; status="failed"; }
      else
        gh api "repos/$TARGET_ORG/$repo_name/milestones" \
          --method POST --input "$_tmp" \
          2>/dev/null || { warn "Failed to create milestone '$title' in $repo_name"; status="failed"; }
      fi
      rm -f "$_tmp"
      pause 0.3
    fi

    local record
    record="$(jq -n --arg title "$title" --arg state "$ms_state" --arg st "$status" --arg ts "$ts" \
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
# _apply_repo_settings — sync PATCH /repos/{owner}/{repo} settings.
# Ordering: regular settings, then default_branch, then archived=true LAST.
_apply_repo_settings() {
  local repo_name="$1" src_repo="$2" state_file="$3"

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
    "allow_update_branch           bool"
    "squash_merge_commit_title     string"
    "squash_merge_commit_message   string"
    "merge_commit_title            string"
    "merge_commit_message          string"
  )

  local ts
  ts="$(now)"

  for setting_def in "${REPO_SETTINGS[@]}"; do
    local field type src_val
    field="$(echo "$setting_def" | awk '{print $1}')"
    type="$(echo  "$setting_def" | awk '{print $2}')"
    src_val="$(echo "$src_repo" | jq -r --arg f "$field" \
      'if .[$f] != null then .[$f] | tostring else empty end' 2>/dev/null || true)"
    [[ -z "$src_val" ]] && continue

    if dry_run_skip "PATCH repos/$TARGET_ORG/$repo_name $field=$src_val"; then
      _upsert_repo_setting "$state_file" "$field" "$src_val" "synced" "$ts"
      continue
    fi

    local result
    if [[ "$type" == "bool" ]]; then
      result="$(gh api "repos/$TARGET_ORG/$repo_name" --method PATCH -F "$field=$src_val" 2>/dev/null)" || result='FAILED'
    else
      result="$(gh api "repos/$TARGET_ORG/$repo_name" --method PATCH -f "$field=$src_val" 2>/dev/null)" || result='FAILED'
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

  local src_default_branch
  src_default_branch="$(echo "$src_repo" | jq -r '.default_branch // empty' 2>/dev/null || true)"
  if [[ -n "$src_default_branch" ]]; then
    if dry_run_skip "PATCH repos/$TARGET_ORG/$repo_name default_branch=$src_default_branch"; then
      _upsert_repo_setting "$state_file" "default_branch" "$src_default_branch" "synced" "$ts"
    else
      local result
      result="$(gh api "repos/$TARGET_ORG/$repo_name" --method PATCH -f "default_branch=$src_default_branch" 2>/dev/null)" || result='FAILED'
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

  local archived
  archived="$(echo "$src_repo" | jq -r '.archived // "false"' 2>/dev/null || echo 'false')"
  if [[ "$archived" == "true" ]]; then
    if dry_run_skip "PATCH repos/$TARGET_ORG/$repo_name archived=true"; then
      _upsert_repo_setting "$state_file" "archived" "true" "synced" "$ts"
    else
      local result
      result="$(gh api "repos/$TARGET_ORG/$repo_name" --method PATCH -F "archived=true" 2>/dev/null)" || result='FAILED'
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
  local state_file="$1" field="$2" value="$3" status="$4" ts="$5"
  local record
  record="$(jq -n \
    --arg type "repo_setting" --arg name "$field" --arg value "$value" \
    --arg status "$status" --arg ts "$ts" \
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
# _apply_pages <repo> <state_file> <pages_json>
# pages_json is the source Pages config object, or null when Pages are disabled.
# custom_domain / https_enforced are intentionally not copied.
_apply_pages() {
  local repo_name="$1" state_file="$2" pages_json="$3"

  [[ -z "$pages_json" || "$pages_json" == "null" ]] && return 0  # Pages not enabled on source

  local src_source_branch src_source_path src_build_type
  src_source_branch="$(echo "$pages_json" | jq -r '.source.branch // "main"')"
  src_source_path="$(echo   "$pages_json" | jq -r '.source.path   // "/"')"
  src_build_type="$(echo    "$pages_json" | jq -r '.build_type    // "legacy"')"

  log "  Syncing Pages settings for $repo_name (branch=$src_source_branch path=$src_source_path build=$src_build_type)..."

  local tgt_pages
  tgt_pages="$(gh api "repos/$TARGET_ORG/$repo_name/pages" 2>/dev/null)" || tgt_pages=""

  local ts
  ts="$(now)"

  if dry_run_skip "configure Pages for $TARGET_ORG/$repo_name (branch=$src_source_branch)"; then
    _upsert_repo_setting "$state_file" "pages_source_branch" "$src_source_branch" "synced" "$ts"
    return 0
  fi

  local status="synced"

  if [[ -z "$tgt_pages" ]]; then
    local create_payload _tmp
    create_payload="$(jq -n --arg branch "$src_source_branch" --arg path "$src_source_path" --arg build "$src_build_type" \
      '{"source":{"branch":$branch,"path":$path},"build_type":$build}')"
    _tmp="$(mktemp)"; printf '%s' "$create_payload" > "$_tmp"
    local _pages_err_tmp create_result _pages_err
    _pages_err_tmp="$(mktemp)"
    create_result="$(gh api "repos/$TARGET_ORG/$repo_name/pages" --method POST --input "$_tmp" 2>"$_pages_err_tmp")" || create_result='FAILED'
    _pages_err="$(cat "$_pages_err_tmp" 2>/dev/null || true)"
    rm -f "$_pages_err_tmp" "$_tmp"

    if [[ "$create_result" == "FAILED" ]]; then
      local create_payload_no_build _tmp2 create_result2
      create_payload_no_build="$(jq -n --arg branch "$src_source_branch" --arg path "$src_source_path" \
        '{"source":{"branch":$branch,"path":$path}}')"
      _tmp2="$(mktemp)"; printf '%s' "$create_payload_no_build" > "$_tmp2"
      create_result2="$(gh api "repos/$TARGET_ORG/$repo_name/pages" --method POST --input "$_tmp2" 2>/dev/null)" || create_result2='FAILED'
      rm -f "$_tmp2"
      if [[ "$create_result2" == "FAILED" ]]; then
        warn "  Failed to enable Pages for $repo_name (branch '$src_source_branch' may not exist yet, or org Pages policy blocks this config) — GitHub: ${_pages_err:-<no details>}"
        status="failed"
      else
        ok "  Enabled Pages for $repo_name (without build_type — org may restrict legacy builds)"
      fi
    else
      ok "  Enabled Pages for $repo_name"
    fi
  else
    local update_payload _tmp
    update_payload="$(jq -n --arg branch "$src_source_branch" --arg path "$src_source_path" --arg build "$src_build_type" \
      '{"source":{"branch":$branch,"path":$path},"build_type":$build}')"
    _tmp="$(mktemp)"; printf '%s' "$update_payload" > "$_tmp"
    local _pages_err_tmp update_result _pages_err
    _pages_err_tmp="$(mktemp)"
    update_result="$(gh api "repos/$TARGET_ORG/$repo_name/pages" --method PUT --input "$_tmp" 2>"$_pages_err_tmp")" || update_result='FAILED'
    _pages_err="$(cat "$_pages_err_tmp" 2>/dev/null || true)"
    rm -f "$_pages_err_tmp" "$_tmp"

    if [[ "$update_result" == "FAILED" ]]; then
      local update_payload_no_build _tmp2 update_result2
      update_payload_no_build="$(jq -n --arg branch "$src_source_branch" --arg path "$src_source_path" \
        '{"source":{"branch":$branch,"path":$path}}')"
      _tmp2="$(mktemp)"; printf '%s' "$update_payload_no_build" > "$_tmp2"
      update_result2="$(gh api "repos/$TARGET_ORG/$repo_name/pages" --method PUT --input "$_tmp2" 2>/dev/null)" || update_result2='FAILED'
      rm -f "$_tmp2"
      if [[ "$update_result2" == "FAILED" ]]; then
        warn "  Failed to update Pages settings for $repo_name — GitHub: ${_pages_err:-<no details>}"
        status="failed"
      else
        ok "  Updated Pages source for $repo_name (build_type skipped — GitHub: ${_pages_err:-org policy})"
      fi
    else
      ok "  Updated Pages settings for $repo_name"
    fi
  fi

  _upsert_repo_setting "$state_file" "pages_source_branch" "$src_source_branch" "$status" "$ts"
  _upsert_repo_setting "$state_file" "pages_source_path"   "$src_source_path"   "$status" "$ts"
  _upsert_repo_setting "$state_file" "pages_build_type"    "$src_build_type"    "$status" "$ts"
}

main "$@"
