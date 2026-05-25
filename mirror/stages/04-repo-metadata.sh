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

main "$@"
