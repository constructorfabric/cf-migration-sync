#!/usr/bin/env bash
# mirror/stages/17-mirror-issue-fields.sh
# Export, create, and apply custom issue field values (Priority, Effort, etc.)
# that live in the issue sidebar and are stored in source_data.issue_field_values.
#
# These are org/repo-level issue fields (distinct from Projects V2 fields).
# Field IDs are org-specific, so we need to:
#   export → fetch field DEFINITIONS from source repos via GraphQL
#             (list of fields with name/dataType/options)
#   import → create matching field definitions in target repos,
#             build source_node_id → target_node_id mapping,
#             apply field values on all mirrored issues
#   CONTINUOUS → re-apply field values to already-mirrored issues
#
# State files:
#   state/issue-field-defs.json   — field definitions from source (per repo)
#   state/issue-field-mapping.json — source→target field/option node_id mapping
#
# Idempotency:
#   - Field creation: if a field with the same name already exists in target, uses it.
#   - Value setting: setIssueFieldValue is upsert-safe (idempotent).
#   - Mapping file preserved across re-runs; only updated when a new field is created.
#
# Usage:
#   SOURCE_ORG=x GH_TOKEN_SOURCE=xxx MIRROR_MODE=export \
#     ./mirror/stages/17-mirror-issue-fields.sh
#   TARGET_ORG=y GH_TOKEN=xxx MIRROR_MODE=import \
#     ./mirror/stages/17-mirror-issue-fields.sh [--repo REPO]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

TARGET_ORG="${TARGET_ORG:-}"
ISSUES_STATE_DIR="$REPO_ROOT/state/issues"
FIELD_DEFS_FILE="$REPO_ROOT/state/issue-field-defs.json"
FIELD_MAP_FILE="$REPO_ROOT/state/issue-field-mapping.json"

# ---------------------------------------------------------------------------
# GraphQL helpers
# ---------------------------------------------------------------------------

# _gql_fetch_field_defs <repo_node_id> — returns the repo's issueFields JSON array
_gql_fetch_field_defs() {
  local repo_nid="$1"
  local resp
  resp="$(GH_TOKEN="${GH_TOKEN_SOURCE:-}" command gh api graphql \
    -f nid="$repo_nid" \
    -f query='
      query($nid:ID!) {
        node(id:$nid) {
          ... on Repository {
            issueFields(first:50) {
              nodes {
                ... on IssueFieldSingleSelect {
                  id name dataType
                  options { id name color description }
                }
                ... on IssueFieldText   { id name dataType }
                ... on IssueFieldNumber { id name dataType }
                ... on IssueFieldDate   { id name dataType }
              }
            }
          }
        }
      }' 2>/dev/null)" || resp=""
  local errmsg
  errmsg="$(printf '%s' "$resp" | jq -r '.errors[0].message // empty' 2>/dev/null || true)"
  [[ -n "$errmsg" ]] && { warn "  [field-defs] GraphQL error: $errmsg"; echo '[]'; return 0; }
  printf '%s' "$resp" | jq -c '.data.node.issueFields.nodes // []' 2>/dev/null || echo '[]'
}

# _gql_repo_node_id <org> <repo> — returns the repo's global node ID
_gql_repo_node_id() {
  local org="$1" repo="$2"
  GH_TOKEN="${GH_TOKEN_SOURCE:-}" command gh api graphql \
    -f org="$org" -f repo="$repo" \
    -f query='query($org:String!,$repo:String!){repository(owner:$org,name:$repo){id}}' \
    2>/dev/null | jq -r '.data.repository.id // empty' 2>/dev/null || true
}

# _gql_target_repo_node_id <org> <repo>
_gql_target_repo_node_id() {
  local org="$1" repo="$2"
  command gh api graphql \
    -f org="$org" -f repo="$repo" \
    -f query='query($org:String!,$repo:String!){repository(owner:$org,name:$repo){id}}' \
    2>/dev/null | jq -r '.data.repository.id // empty' 2>/dev/null || true
}

# _gql_create_field <repo_node_id> <name> <data_type> <options_json>
# data_type: SINGLE_SELECT | TEXT | NUMBER | DATE
# Returns node_id of the created/found field, empty on failure.
_gql_create_field_in_target() {
  local repo_nid="$1" name="$2" dtype="$3" options_json="$4"
  local resp new_nid

  # First check if a field with this name already exists.
  local existing_resp
  existing_resp="$(command gh api graphql \
    -f nid="$repo_nid" \
    -f query='query($nid:ID!){node(id:$nid){... on Repository{issueFields(first:50){nodes{
      ... on IssueFieldSingleSelect{id name}
      ... on IssueFieldText{id name}
      ... on IssueFieldNumber{id name}
      ... on IssueFieldDate{id name}
    }}}}}' 2>/dev/null)" || existing_resp=""
  local existing_id
  existing_id="$(printf '%s' "$existing_resp" | \
    jq -r --arg n "$name" \
    '.data.node.issueFields.nodes[]? | select(.name==$n) | .id // empty' \
    2>/dev/null | head -1 || true)"
  if [[ -n "$existing_id" ]]; then
    echo "$existing_id"; return 0
  fi

  # Create the field.
  if [[ "$dtype" == "SINGLE_SELECT" ]]; then
    # Build options array; color must be uppercase enum value.
    local opts_input _opt_tmp
    opts_input="$(printf '%s' "$options_json" | jq -c '
      [.[] | {
        name:        .name,
        color:       ((.color // "GRAY") | ascii_upcase),
        description: (.description // "")
      }]' 2>/dev/null || echo '[]')"
    _opt_tmp="$(mktemp)"
    printf '%s' "$opts_input" > "$_opt_tmp"
    resp="$(command gh api graphql \
      -f rid="$repo_nid" -f n="$name" -f dt="$dtype" \
      --slurpfile opts "$_opt_tmp" \
      -f query='
        mutation($rid:ID!, $n:String!, $dt:IssueFieldDataType!, $opts:[IssueFieldSingleSelectOptionInput!]) {
          createIssueField(input:{ownerId:$rid, name:$n, dataType:$dt, options:$opts}) {
            issueField {
              ... on IssueFieldSingleSelect { id name }
            }
          }
        }' 2>/dev/null)" || resp=""
    rm -f "$_opt_tmp"
    new_nid="$(printf '%s' "$resp" | jq -r '.data.createIssueField.issueField.id // empty' 2>/dev/null || true)"
  else
    resp="$(command gh api graphql \
      -f rid="$repo_nid" -f n="$name" -f dt="$dtype" \
      -f query='
        mutation($rid:ID!, $n:String!, $dt:IssueFieldDataType!) {
          createIssueField(input:{ownerId:$rid, name:$n, dataType:$dt}) {
            issueField {
              ... on IssueFieldText   { id name }
              ... on IssueFieldNumber { id name }
              ... on IssueFieldDate   { id name }
            }
          }
        }' 2>/dev/null)" || resp=""
    new_nid="$(printf '%s' "$resp" | jq -r '.data.createIssueField.issueField.id // empty' 2>/dev/null || true)"
  fi

  local errmsg
  errmsg="$(printf '%s' "$resp" | jq -r '.errors[0].message // empty' 2>/dev/null || true)"
  [[ -n "$errmsg" ]] && warn "  [create-field] $name: GraphQL error: $errmsg"
  echo "$new_nid"
}

# _gql_set_field_values <issue_node_id> <fields_json>
# fields_json: [{fieldId:"IFSS_...", singleSelectOptionId:"IFSSO_..."}]
_gql_set_field_values() {
  local issue_nid="$1" fields_json="$2"
  local _ftmp resp
  _ftmp="$(mktemp)"; printf '%s' "$fields_json" > "$_ftmp"
  resp="$(command gh api graphql \
    -f iid="$issue_nid" \
    --slurpfile fv "$_ftmp" \
    -f query='
      mutation($iid:ID!, $fv:[IssueFieldCreateOrUpdateInput!]!) {
        setIssueFieldValue(input:{issueId:$iid, issueFields:$fv}) {
          issue { id }
        }
      }' 2>/dev/null)" || resp=""
  rm -f "$_ftmp"
  local errmsg
  errmsg="$(printf '%s' "$resp" | jq -r '.errors[0].message // empty' 2>/dev/null || true)"
  [[ -n "$errmsg" ]] && { warn "  [set-field-values] GraphQL error: $errmsg"; return 1; }
  return 0
}

# ---------------------------------------------------------------------------
# Export: fetch field definitions from source repos
# ---------------------------------------------------------------------------
_run_export() {
  log "  Fetching issue field definitions from source repos..."
  local all_defs="{}"
  local repos_with_fields=0

  while IFS= read -r repo_name; do
    [[ -z "$repo_name" ]] && continue

    # Check if this repo has any issues with field values in state.
    local state_file="$ISSUES_STATE_DIR/$repo_name.yaml"
    state_unsplit "$state_file"
    [[ -f "$state_file" ]] || continue
    local has_fv
    has_fv="$(jq '[.items[] | select(.source_data.issue_field_values != null and (.source_data.issue_field_values|length>0))] | length' "$state_file" 2>/dev/null || echo 0)"
    [[ "$has_fv" -eq 0 ]] && { state_split_if_needed "$state_file"; continue; }

    log "  $repo_name: $has_fv issues have field values — fetching field definitions..."
    local repo_nid
    repo_nid="$(_gql_repo_node_id "$SOURCE_ORG" "$repo_name")"
    if [[ -z "$repo_nid" ]]; then
      warn "  $repo_name: could not resolve node_id — skipping field defs"
      state_split_if_needed "$state_file"
      continue
    fi

    local defs
    defs="$(_gql_fetch_field_defs "$repo_nid")"
    if [[ "$(echo "$defs" | jq 'length')" -eq 0 ]]; then
      warn "  $repo_name: no issue field definitions returned"
      state_split_if_needed "$state_file"
      continue
    fi

    all_defs="$(echo "$all_defs" | jq --arg r "$repo_name" --argjson d "$defs" '.[$r] = $d')"
    ok "  $repo_name: $(echo "$defs" | jq 'length') field definition(s) captured"
    repos_with_fields=$((repos_with_fields + 1))
    state_split_if_needed "$state_file"
    pause 0.3
  done < <(state_repo_names "$ISSUES_STATE_DIR")

  printf '%s' "$all_defs" | jq '.' > "$FIELD_DEFS_FILE"
  log "Stage 17 (export) complete — field defs for $repos_with_fields repos written to $FIELD_DEFS_FILE"
  [[ "$DRY_RUN" -eq 0 ]] && commit_state "mirror: export stage 17 (issue-field-defs) [skip ci]"
}

# ---------------------------------------------------------------------------
# Import: create fields in target, build mapping, apply values
# ---------------------------------------------------------------------------
_run_import() {
  if [[ ! -f "$FIELD_DEFS_FILE" ]]; then
    warn "No field definitions at $FIELD_DEFS_FILE — run MIRROR_MODE=export first"
    return 0
  fi

  local repo_names
  repo_names="$(jq -r 'keys[]' "$FIELD_DEFS_FILE" 2>/dev/null || true)"
  if [[ -z "$repo_names" ]]; then
    log "No repos with issue field definitions — nothing to do"
    return 0
  fi

  # Load or initialize the mapping file.
  [[ -f "$FIELD_MAP_FILE" ]] || echo '{}' > "$FIELD_MAP_FILE"

  local total_applied=0 total_skipped=0 total_failed=0

  while IFS= read -r repo_name; do
    [[ -z "$repo_name" ]] && continue
    log "  Processing issue fields for $repo_name..."

    # Resolve target repo node_id once.
    local tgt_repo_nid
    tgt_repo_nid="$(_gql_target_repo_node_id "$TARGET_ORG" "$repo_name")"
    if [[ -z "$tgt_repo_nid" ]]; then
      warn "  $repo_name: could not resolve target repo node_id — skipping"
      continue
    fi

    # Get source field definitions for this repo.
    local src_fields
    src_fields="$(jq -c --arg r "$repo_name" '.[$r] // []' "$FIELD_DEFS_FILE")"
    local field_count
    field_count="$(echo "$src_fields" | jq 'length')"
    [[ "$field_count" -eq 0 ]] && continue

    # For each source field: ensure it exists in target, store mapping.
    local field_idx=0
    while IFS= read -r field; do
      [[ -z "$field" ]] && continue
      local src_fid fname ftype src_options
      src_fid="$(echo "$field" | jq -r '.id')"
      fname="$(echo "$field" | jq -r '.name')"
      ftype="$(echo "$field" | jq -r '.dataType')"
      src_options="$(echo "$field" | jq -c '.options // []')"

      field_idx=$((field_idx + 1))
      if dry_run_skip "ensure field '$fname' ($ftype) exists in $TARGET_ORG/$repo_name"; then
        continue
      fi

      # Create (or find) the field in the target repo.
      local tgt_fid
      tgt_fid="$(_gql_create_field_in_target "$tgt_repo_nid" "$fname" "$ftype" "$src_options")"
      if [[ -z "$tgt_fid" ]]; then
        warn "  $repo_name: could not create/find field '$fname' in target"
        continue
      fi
      ok "  $repo_name: field '$fname' → target $tgt_fid"

      # Build option mapping (by name, since names are stable across orgs).
      local opt_map="{}"
      if [[ "$ftype" == "SINGLE_SELECT" ]]; then
        # Fetch target field options to get their IDs.
        local tgt_field_data
        tgt_field_data="$(command gh api graphql \
          -f fid="$tgt_fid" \
          -f query='query($fid:ID!){node(id:$fid){... on IssueFieldSingleSelect{options{id name}}}}' \
          2>/dev/null | jq -c '.data.node.options // []' 2>/dev/null || echo '[]')"
        # Map option name → target option node_id.
        while IFS= read -r opt; do
          [[ -z "$opt" ]] && continue
          local oname otid
          oname="$(echo "$opt" | jq -r '.name')"
          otid="$(echo "$opt" | jq -r '.id')"
          opt_map="$(echo "$opt_map" | jq --arg n "$oname" --arg id "$otid" '.[$n] = $id')"
        done < <(echo "$tgt_field_data" | jq -c '.[]' 2>/dev/null || true)
      fi

      # Store mapping: repo → src_field_id → {target_field_id, options_map}
      local tmp; tmp="$(mktemp)"
      jq --arg r "$repo_name" --arg sfid "$src_fid" --arg tfid "$tgt_fid" \
         --argjson opts "$opt_map" \
        '.[$r][$sfid] = {target_field_id:$tfid, options:$opts}' \
        "$FIELD_MAP_FILE" > "$tmp" && mv "$tmp" "$FIELD_MAP_FILE"

    done < <(echo "$src_fields" | jq -c '.[]')

    [[ "$DRY_RUN" -eq 0 ]] && commit_state "mirror: stage 17 field defs for $repo_name [skip ci]"

    # Apply field values to all mirrored issues in this repo.
    log "  Applying field values to mirrored issues in $repo_name..."
    local state_file="$ISSUES_STATE_DIR/$repo_name.yaml"
    state_unsplit "$state_file"
    [[ -f "$state_file" ]] || continue

    local result
    result="$(_apply_field_values "$repo_name" "$state_file")"
    total_applied=$(( total_applied + $(echo "$result" | jq -r '.applied // 0') ))
    total_skipped=$(( total_skipped + $(echo "$result" | jq -r '.skipped // 0') ))
    total_failed=$(( total_failed  + $(echo "$result" | jq -r '.failed  // 0') ))

    state_split_if_needed "$state_file"
  done < <(echo "$repo_names")

  log "Stage 17 (import) complete — applied=$total_applied skipped=$total_skipped failed=$total_failed"
  [[ "$DRY_RUN" -eq 0 ]] && commit_state "mirror: stage 17 (issue-field-values applied) [skip ci]"
}

# _apply_field_values <repo_name> <state_file>
# Applies stored field values to all mirrored issues using the field mapping.
# Outputs JSON {applied, skipped, failed}.
_apply_field_values() {
  local repo_name="$1" state_file="$2"
  local applied=0 skipped=0 failed=0

  [[ -f "$FIELD_MAP_FILE" ]] || { echo '{"applied":0,"skipped":0,"failed":0}'; return 0; }

  local repo_map
  repo_map="$(jq -c --arg r "$repo_name" '.[$r] // {}' "$FIELD_MAP_FILE" 2>/dev/null || echo '{}')"
  if [[ "$repo_map" == "{}" ]]; then
    echo '{"applied":0,"skipped":0,"failed":0}'; return 0
  fi

  # Issues that have field values AND are mirrored.
  local items
  items="$(jq -c '
    [.items[] |
      select(
        .status == "mirrored" and
        .target_number != null and
        (.source_data.issue_field_values // [] | length) > 0
      ) |
      {
        src: .source_number,
        tgt: .target_number,
        tgt_node_id: .target_node_id,
        fv: (.source_data.issue_field_values // [])
      }
    ]' "$state_file" 2>/dev/null || echo '[]')"

  local count
  count="$(echo "$items" | jq 'length')"
  [[ "$count" -eq 0 ]] && { echo '{"applied":0,"skipped":0,"failed":0}'; return 0; }
  log "  $repo_name: applying field values on $count issue(s)"

  while IFS= read -r item; do
    [[ -z "$item" ]] && continue
    local src tgt tgt_nid fv
    src="$(echo "$item" | jq -r '.src')"
    tgt="$(echo "$item" | jq -r '.tgt')"
    tgt_nid="$(echo "$item" | jq -r '.tgt_node_id // empty')"
    fv="$(echo "$item" | jq -c '.fv')"

    # Resolve target node_id if not stored.
    if [[ -z "$tgt_nid" || "$tgt_nid" == "null" ]]; then
      tgt_nid="$(command gh api "repos/$TARGET_ORG/$repo_name/issues/$tgt" 2>/dev/null \
        | jq -r '.node_id // empty' 2>/dev/null || true)"
    fi
    if [[ -z "$tgt_nid" ]]; then
      warn "  $repo_name #$src: cannot get target issue node_id — skipping"
      failed=$((failed + 1)); continue
    fi

    # Build the IssueFieldCreateOrUpdateInput array using the mapping.
    local fields_input="[]"
    while IFS= read -r fval; do
      [[ -z "$fval" ]] && continue
      local src_fid dtype val opt_name
      src_fid="$(echo "$fval" | jq -r '.issue_field_id | tostring')"
      dtype="$(echo "$fval" | jq -r '.data_type')"
      val="$(echo "$fval" | jq -r '.value // empty')"
      opt_name="$(echo "$fval" | jq -r '.single_select_option.name // empty')"

      # Look up target field ID from mapping.
      local tgt_fid
      tgt_fid="$(echo "$repo_map" | jq -r --arg sid "$src_fid" '.[$sid].target_field_id // empty' 2>/dev/null || true)"
      if [[ -z "$tgt_fid" ]]; then
        warn "  $repo_name #$src: no mapping for source field $src_fid — run import to create it"
        skipped=$((skipped + 1)); continue
      fi

      local field_entry="{}"
      case "$dtype" in
        single_select|SINGLE_SELECT)
          local tgt_opt_id
          tgt_opt_id="$(echo "$repo_map" | jq -r \
            --arg sid "$src_fid" --arg oname "$opt_name" \
            '.[$sid].options[$oname] // empty' 2>/dev/null || true)"
          if [[ -z "$tgt_opt_id" ]]; then
            warn "  $repo_name #$src: no mapping for option '$opt_name' on field $src_fid"
            skipped=$((skipped + 1)); continue
          fi
          field_entry="$(jq -n --arg fid "$tgt_fid" --arg oid "$tgt_opt_id" \
            '{fieldId:$fid, singleSelectOptionId:$oid}')"
          ;;
        text|TEXT)
          field_entry="$(jq -n --arg fid "$tgt_fid" --arg v "$val" '{fieldId:$fid, textValue:$v}')"
          ;;
        number|NUMBER)
          field_entry="$(jq -n --arg fid "$tgt_fid" --argjson v "${val:-0}" '{fieldId:$fid, numberValue:$v}')"
          ;;
        date|DATE)
          field_entry="$(jq -n --arg fid "$tgt_fid" --arg v "$val" '{fieldId:$fid, dateValue:$v}')"
          ;;
        *) warn "  $repo_name #$src: unsupported field type '$dtype' — skipping"; continue ;;
      esac

      fields_input="$(jq -cn --argjson arr "$fields_input" --argjson e "$field_entry" '$arr + [$e]')"
    done < <(echo "$fv" | jq -c '.[]' 2>/dev/null || true)

    [[ "$(echo "$fields_input" | jq 'length')" -eq 0 ]] && { skipped=$((skipped+1)); continue; }

    if dry_run_skip "set field values on $repo_name #$tgt (src #$src)"; then
      applied=$((applied + 1)); continue
    fi

    if _gql_set_field_values "$tgt_nid" "$fields_input"; then
      ok "  $repo_name #$tgt (src #$src): field values applied"
      applied=$((applied + 1))
    else
      warn "  $repo_name #$tgt (src #$src): failed to apply field values"
      failed=$((failed + 1))
    fi
    pause 0.3

  done < <(echo "$items" | jq -c '.[]')

  echo "{\"applied\":$applied,\"skipped\":$skipped,\"failed\":$failed}"
}

# ---------------------------------------------------------------------------
main() {
  local only_repo=""
  local passthrough_args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) only_repo="$2"; shift 2 ;;
      *)      passthrough_args+=("$1"); shift ;;
    esac
  done

  check_dry_run "${passthrough_args[@]+"${passthrough_args[@]}"}"
  preflight

  log "Stage 17 — mirror-issue-fields starting (mode=$MIRROR_MODE)"

  if in_export; then
    _run_export
    return 0
  fi

  if writes_target; then
    _run_import
    return 0
  fi

  warn "Stage 17: nothing to do in mode=$MIRROR_MODE"
}

main "$@"
