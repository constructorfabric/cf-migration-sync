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

  gh api "repos/$TARGET_ORG/$repo_name/topics" \
    --method PUT \
    -H "Accept: application/vnd.github.mercy-preview+json" \
    --input <(echo "$src_topics") \
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
  tgt_labels="$(gh_paginate gh "repos/$TARGET_ORG/$repo_name/labels" 2>/dev/null || echo '[]')"

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
      local encoded_name
      encoded_name="$(python3 -c "import urllib.parse; print(urllib.parse.quote('$lname'))" 2>/dev/null || echo "$lname" | sed 's/ /%20/g')"
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
    2>/dev/null || echo '[]')"
  src_closed="$(ghsrc api "repos/$SOURCE_ORG/$repo_name/milestones?state=closed&per_page=100" \
    2>/dev/null || echo '[]')"
  src_milestones="$(echo "$src_open $src_closed" | jq -s 'add // []')"

  local ms_count
  ms_count="$(echo "$src_milestones" | jq 'length')"

  if [[ "$ms_count" -eq 0 ]]; then
    return 0
  fi

  log "  Found $ms_count source milestones"

  # Fetch existing target milestones
  local tgt_open tgt_closed tgt_milestones
  tgt_open="$(gh_paginate gh "repos/$TARGET_ORG/$repo_name/milestones" \
    2>/dev/null || echo '[]')"
  tgt_closed="$(gh api "repos/$TARGET_ORG/$repo_name/milestones?state=closed&per_page=100" \
    2>/dev/null || echo '[]')"
  tgt_milestones="$(echo "$tgt_open $tgt_closed" | jq -s 'add // []')"

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
        --method PATCH -F "$field=$src_val" 2>/dev/null || echo 'FAILED')"
    else
      result="$(gh api "repos/$TARGET_ORG/$repo_name" \
        --method PATCH -f "$field=$src_val" 2>/dev/null || echo 'FAILED')"
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
        2>/dev/null || echo 'FAILED')"
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
        --method PATCH -F "archived=true" 2>/dev/null || echo 'FAILED')"
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

main "$@"
