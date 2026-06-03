#!/usr/bin/env bash
# mirror/stages/15-export-projects.sh
# Export AND (best-effort) import of organization Projects V2 — the modern GitHub
# Projects (tables / boards / roadmaps): custom fields, items, DRAFT ISSUES
# (org-level issues not linked to any repo), and views/dashboards.
#
# Projects V2 is GraphQL-only (no REST). Stage 09 inventories projects shallowly;
# this stage captures the FULL configuration and replays what GitHub's API allows.
#
# ---------------------------------------------------------------------------
# What import CAN do automatically (GraphQL mutations):
#   * create the project (title + short description)
#   * recreate custom fields: TEXT, NUMBER, DATE, SINGLE_SELECT (with options)
#   * recreate DRAFT ISSUES (title + body) as project items
#   * set field values on draft issues (text/number/date/single-select)
#
# What import CANNOT do (no GitHub write API, or requires cross-stage mapping) —
# these are written to a detailed, step-by-step manual-instructions report at
#   state/projects-manual-import.md
#   * VIEWS / dashboards (board/table/roadmap layouts, filters, grouping, sorting)
#       — GitHub exposes no mutation to create or configure a view.
#   * ITERATION fields — no stable create mutation; must be added by hand.
#   * Re-linking items that referenced a repo ISSUE/PR — the target issue/PR
#       numbers differ from source and live in other state files; relinking is a
#       manual (or future cross-reference) step.
#   * Project README, built-in workflows, insights/charts, status updates.
#
# State file: state/projects.yaml   (split automatically if it exceeds the limit)
# Manual report (import mode): state/projects-manual-import.md
#
# Modes (MIRROR_MODE):
#   export — fetch + serialize everything from source. NEVER touches target.
#   full   — treated as export (source-read only; never writes target).
#   import — recreate what the API allows in the target org, and emit the manual
#            report for the rest. NEVER touches the source.
#
# Tokens:
#   export → GH_TOKEN_SOURCE with read:project scope.
#   import → GH_TOKEN with project scope (read+write) on the TARGET org.
#
# Usage:
#   # export
#   SOURCE_ORG=cyberfabric GH_TOKEN_SOURCE=xxx MIRROR_MODE=export \
#     ./mirror/stages/15-export-projects.sh [--dry-run]
#   # import
#   TARGET_ORG=constructorfabric GH_TOKEN=xxx MIRROR_MODE=import \
#     ./mirror/stages/15-export-projects.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

STATE_FILE="$REPO_ROOT/state/projects.yaml"
MANUAL_REPORT="$REPO_ROOT/state/projects-manual-import.md"

# Page sizes for the paginated GraphQL sub-collections.
PROJECTS_PAGE=20
FIELDS_PAGE=50
VIEWS_PAGE=50
ITEMS_PAGE=50

# ===========================================================================
# EXPORT — GraphQL read helpers (source org)
# ===========================================================================

# _gql_projects_page <org> <after>
_gql_projects_page() {
  local org="$1" after="$2"
  ghsrc api graphql \
    -f org="$org" \
    -F after="$after" \
    -f query='
      query($org:String!, $after:String) {
        organization(login:$org) {
          projectsV2(first:'"$PROJECTS_PAGE"', after:$after) {
            pageInfo { hasNextPage endCursor }
            nodes {
              id number title shortDescription public closed
              createdAt updatedAt url
              readme
              creator { login }
            }
          }
        }
      }' 2>/dev/null
}

# _gql_fields <project_id>
_gql_fields() {
  local pid="$1"
  ghsrc api graphql \
    -f pid="$pid" \
    -f query='
      query($pid:ID!) {
        node(id:$pid) {
          ... on ProjectV2 {
            fields(first:'"$FIELDS_PAGE"') {
              nodes {
                __typename
                ... on ProjectV2FieldCommon { id name dataType }
                ... on ProjectV2SingleSelectField {
                  id name dataType
                  options { id name color description }
                }
                ... on ProjectV2IterationField {
                  id name dataType
                  configuration {
                    duration startDay
                    iterations { id title startDate duration }
                    completedIterations { id title startDate duration }
                  }
                }
              }
            }
          }
        }
      }' 2>/dev/null
}

# _gql_views <project_id>
_gql_views() {
  local pid="$1"
  ghsrc api graphql \
    -f pid="$pid" \
    -f query='
      query($pid:ID!) {
        node(id:$pid) {
          ... on ProjectV2 {
            views(first:'"$VIEWS_PAGE"') {
              nodes { id number name layout filter }
            }
          }
        }
      }' 2>/dev/null
}

# _gql_items_page <project_id> <after>
_gql_items_page() {
  local pid="$1" after="$2"
  ghsrc api graphql \
    -f pid="$pid" \
    -F after="$after" \
    -f query='
      query($pid:ID!, $after:String) {
        node(id:$pid) {
          ... on ProjectV2 {
            items(first:'"$ITEMS_PAGE"', after:$after) {
              pageInfo { hasNextPage endCursor }
              nodes {
                id type createdAt updatedAt
                fieldValues(first:50) {
                  nodes {
                    __typename
                    ... on ProjectV2ItemFieldTextValue        { text  field { ... on ProjectV2FieldCommon { name } } }
                    ... on ProjectV2ItemFieldNumberValue      { number field { ... on ProjectV2FieldCommon { name } } }
                    ... on ProjectV2ItemFieldDateValue        { date  field { ... on ProjectV2FieldCommon { name } } }
                    ... on ProjectV2ItemFieldSingleSelectValue { name optionId field { ... on ProjectV2FieldCommon { name } } }
                    ... on ProjectV2ItemFieldIterationValue   { title iterationId startDate duration field { ... on ProjectV2FieldCommon { name } } }
                  }
                }
                content {
                  __typename
                  ... on DraftIssue { title body }
                  ... on Issue        { number title url repository { nameWithOwner } }
                  ... on PullRequest  { number title url repository { nameWithOwner } }
                }
              }
            }
          }
        }
      }' 2>/dev/null
}

# _fetch_all_items <project_id> — paginate every item, print one JSON array.
_fetch_all_items() {
  local pid="$1"
  local after="null"
  local all="[]"
  while :; do
    local page
    page="$(_gql_items_page "$pid" "$after")" || page=""
    [[ -z "$page" ]] && break
    local nodes
    nodes="$(echo "$page" | jq -c '.data.node.items.nodes // []' 2>/dev/null || echo '[]')"
    all="$(jq -cn --argjson a "$all" --argjson b "$nodes" '$a + $b')"
    local has_next end_cursor
    has_next="$(echo "$page" | jq -r '.data.node.items.pageInfo.hasNextPage // false' 2>/dev/null || echo false)"
    end_cursor="$(echo "$page" | jq -r '.data.node.items.pageInfo.endCursor // empty' 2>/dev/null || true)"
    [[ "$has_next" == "true" && -n "$end_cursor" ]] || break
    after="$end_cursor"
    pause 0.3
  done
  echo "$all"
}

# ===========================================================================
# IMPORT — GraphQL write helpers (target org). All go through gh() so the
# write-throttle engine paces them (graphql mutations are detected as writes).
# ===========================================================================

# _gql_target_org_id <org> — resolve the target org's node ID (needed as ownerId
# _gql_warn_errors <response_json> <context> — if the GraphQL response carries a
# top-level .errors array (permission/scope/validation failures that GitHub returns
# with HTTP 200 + an errors body), log the first message. Returns 0 if errors were
# present, 1 otherwise. This is the H7/M3 fix: a GraphQL error is no longer
# indistinguishable from "empty result" — it is surfaced loudly.
_gql_warn_errors() {
  local resp="$1" ctx="$2"
  local msg
  msg="$(printf '%s' "$resp" | jq -r '.errors[0].message // empty' 2>/dev/null || true)"
  if [[ -n "$msg" ]]; then
    warn "  [gql] $ctx — GitHub error: $msg"
    return 0
  fi
  return 1
}

# for createProjectV2). Echoes the id, or empty on failure.
_gql_target_org_id() {
  local org="$1"
  # RC-5 corollary: capture out-of-band (do NOT pipe gh→jq, which hides the error
  # body and exit code). Then surface GraphQL errors before extracting.
  local resp
  resp="$(gh api graphql -f login="$org" \
    -f query='query($login:String!){organization(login:$login){id}}' \
    2>/dev/null)" || resp=""
  _gql_warn_errors "$resp" "resolve org '$org' id" || true
  printf '%s' "$resp" | jq -r '.data.organization.id // empty' 2>/dev/null || true
}

# _gql_create_project <owner_id> <title> <short_desc> — create a ProjectV2.
# Echoes "<project_id>\t<project_number>" on success, empty on failure.
_gql_create_project() {
  local owner_id="$1" title="$2" desc="$3"
  local resp
  resp="$(gh api graphql \
    -f ownerId="$owner_id" \
    -f title="$title" \
    -f query='
      mutation($ownerId:ID!, $title:String!) {
        createProjectV2(input:{ownerId:$ownerId, title:$title}) {
          projectV2 { id number }
        }
      }' 2>/dev/null)" || resp=""
  _gql_warn_errors "$resp" "create project '$title'" || true
  local pid pnum
  pid="$(echo "$resp" | jq -r '.data.createProjectV2.projectV2.id // empty' 2>/dev/null || true)"
  pnum="$(echo "$resp" | jq -r '.data.createProjectV2.projectV2.number // empty' 2>/dev/null || true)"
  # pid (node ID) is the authoritative result. Fail only if it is absent.
  [[ -z "$pid" ]] && return 1
  # number should always accompany a successful create; default to 0 if the API
  # omitted it so downstream --argjson never receives an empty string (BUG-A).
  [[ -z "$pnum" || "$pnum" == "null" ]] && pnum=0
  # Best-effort: set the short description if present (separate mutation).
  if [[ -n "$desc" && "$desc" != "null" ]]; then
    gh api graphql -f pid="$pid" -f d="$desc" \
      -f query='mutation($pid:ID!,$d:String!){updateProjectV2(input:{projectId:$pid,shortDescription:$d}){projectV2{id}}}' \
      &>/dev/null || true
  fi
  printf '%s\t%s' "$pid" "$pnum"
}

# _gql_create_field <project_id> <name> <dataType> <options_json>
# dataType ∈ TEXT|NUMBER|DATE|SINGLE_SELECT. For SINGLE_SELECT, options_json is
# an array of {name,color,description}; GitHub requires at least one option and a
# valid color enum (RED|ORANGE|YELLOW|GREEN|BLUE|PURPLE|PINK|GRAY). Unknown colors
# fall back to GRAY. Echoes the new field id, empty on failure.
_gql_create_field() {
  local pid="$1" name="$2" dtype="$3" options="$4"
  if [[ "$dtype" == "SINGLE_SELECT" ]]; then
    # Normalize options to the mutation's SingleSelectOptionInput shape.
    local opts_input
    opts_input="$(printf '%s' "$options" | jq -c '
      [ .[] | {
          name: .name,
          color: ((.color // "GRAY") | ascii_upcase |
                   if (["RED","ORANGE","YELLOW","GREEN","BLUE","PURPLE","PINK","GRAY"] | index(.)) then . else "GRAY" end),
          description: (.description // "")
        } ]' 2>/dev/null || echo '[]')"
    # GitHub rejects single-select creation with zero options.
    if [[ "$(echo "$opts_input" | jq 'length')" -eq 0 ]]; then
      opts_input='[{"name":"(placeholder)","color":"GRAY","description":""}]'
    fi
    local _opt_tmp resp
    _opt_tmp="$(mktemp)"; printf '%s' "$opts_input" > "$_opt_tmp"
    # RC-5 corollary (H7 fix): capture out-of-band, surface errors, then extract.
    resp="$(gh api graphql \
      -f pid="$pid" -f name="$name" \
      --slurpfile opts "$_opt_tmp" \
      -f query='
        mutation($pid:ID!, $name:String!, $opts:[ProjectV2SingleSelectFieldOptionInput!]!) {
          createProjectV2Field(input:{
            projectId:$pid, dataType:SINGLE_SELECT, name:$name, singleSelectOptions:$opts
          }) { projectV2Field { ... on ProjectV2SingleSelectField { id } } }
        }' 2>/dev/null)" || resp=""
    rm -f "$_opt_tmp"
    _gql_warn_errors "$resp" "create single-select field '$name'" || true
    printf '%s' "$resp" | jq -r '.data.createProjectV2Field.projectV2Field.id // empty' 2>/dev/null || true
  else
    local resp
    resp="$(gh api graphql \
      -f pid="$pid" -f name="$name" -f dt="$dtype" \
      -f query='
        mutation($pid:ID!, $name:String!, $dt:ProjectV2CustomFieldType!) {
          createProjectV2Field(input:{projectId:$pid, dataType:$dt, name:$name}) {
            projectV2Field { ... on ProjectV2FieldCommon { id } }
          }
        }' 2>/dev/null)" || resp=""
    _gql_warn_errors "$resp" "create $dtype field '$name'" || true
    printf '%s' "$resp" | jq -r '.data.createProjectV2Field.projectV2Field.id // empty' 2>/dev/null || true
  fi
}

# _gql_add_draft <project_id> <title> <body> — add a draft issue.
# Echoes the new project ITEM id, empty on failure. Body via --slurpfile-free
# stdin? gh graphql needs -f; large bodies use a temp file + --field.
_gql_add_draft() {
  local pid="$1" title="$2" body="$3"
  local _btmp resp
  _btmp="$(mktemp)"; printf '%s' "$body" > "$_btmp"
  # Pass the (possibly large) body via @file to stay ARG_MAX-safe (RC-6).
  # RC-5 corollary (H7 fix): capture out-of-band, surface errors, then extract.
  resp="$(gh api graphql \
    -f pid="$pid" -f title="$title" -F body="@$_btmp" \
    -f query='
      mutation($pid:ID!, $title:String!, $body:String!) {
        addProjectV2DraftIssue(input:{projectId:$pid, title:$title, body:$body}) {
          projectItem { id }
        }
      }' 2>/dev/null)" || resp=""
  rm -f "$_btmp"
  _gql_warn_errors "$resp" "add draft issue '$title'" || true
  printf '%s' "$resp" | jq -r '.data.addProjectV2DraftIssue.projectItem.id // empty' 2>/dev/null || true
}

# ===========================================================================
# EXPORT driver
# ===========================================================================
_run_export() {
  state_unsplit "$STATE_FILE"
  state_init "$STATE_FILE" "15-export-projects"

  log "Fetching Projects V2 from $SOURCE_ORG..."
  local projects="[]" after="null"
  while :; do
    local page
    page="$(_gql_projects_page "$SOURCE_ORG" "$after")" || page=""
    if [[ -z "$page" ]]; then
      warn "  Projects query returned nothing — check that GH_TOKEN_SOURCE has read:project scope"
      break
    fi
    local errmsg
    errmsg="$(echo "$page" | jq -r '.errors[0].message // empty' 2>/dev/null || true)"
    if [[ -n "$errmsg" ]]; then
      err "  GraphQL error fetching projects: $errmsg"
      err "  (a 'read:project' / 'project' token scope is required)"
      break
    fi
    local nodes
    nodes="$(echo "$page" | jq -c '.data.organization.projectsV2.nodes // []' 2>/dev/null || echo '[]')"
    projects="$(jq -cn --argjson a "$projects" --argjson b "$nodes" '$a + $b')"
    local has_next end_cursor
    has_next="$(echo "$page" | jq -r '.data.organization.projectsV2.pageInfo.hasNextPage // false' 2>/dev/null || echo false)"
    end_cursor="$(echo "$page" | jq -r '.data.organization.projectsV2.pageInfo.endCursor // empty' 2>/dev/null || true)"
    [[ "$has_next" == "true" && -n "$end_cursor" ]] || break
    after="$end_cursor"
    pause 0.3
  done

  local project_count
  project_count="$(echo "$projects" | jq 'length' 2>/dev/null || echo 0)"
  log "Found $project_count Projects V2 in $SOURCE_ORG"

  if [[ "$project_count" -eq 0 ]]; then
    state_update_stats "$STATE_FILE"
    [[ "$DRY_RUN" -eq 0 ]] && commit_state "mirror: export stage 15 (projects) — none found [skip ci]"
    log "Stage 15 complete (export) — 0 projects"
    return 0
  fi

  if dry_run_skip "deep-export $project_count Projects V2 (fields, views, items, draft issues)"; then
    return 0
  fi

  local exported=0 draft_total=0
  while IFS= read -r proj; do
    local pid number title
    pid="$(echo    "$proj" | jq -r '.id')"
    number="$(echo "$proj" | jq -r '.number')"
    title="$(echo  "$proj" | jq -r '.title')"
    log "  [export] Project #$number '$title' — fetching fields, views, items..."

    local fields views items
    fields="$(_gql_fields "$pid" | jq -c '.data.node.fields.nodes // []' 2>/dev/null || echo '[]')"
    pause 0.3
    views="$(_gql_views "$pid" | jq -c '.data.node.views.nodes // []' 2>/dev/null || echo '[]')"
    pause 0.3
    items="$(_fetch_all_items "$pid")"

    local fcount vcount icount dcount
    fcount="$(echo "$fields" | jq 'length' 2>/dev/null || echo 0)"
    vcount="$(echo "$views"  | jq 'length' 2>/dev/null || echo 0)"
    icount="$(echo "$items"  | jq 'length' 2>/dev/null || echo 0)"
    dcount="$(echo "$items"  | jq '[.[] | select(.content.__typename == "DraftIssue")] | length' 2>/dev/null || echo 0)"
    draft_total=$(( draft_total + dcount ))
    log "    fields=$fcount views=$vcount items=$icount (draft-issues=$dcount)"

    local _p _f _v _i _rec _st
    _p="$(mktemp)"; _f="$(mktemp)"; _v="$(mktemp)"; _i="$(mktemp)"; _rec="$(mktemp)"; _st="$(mktemp)"
    printf '%s' "$proj"   > "$_p"
    printf '%s' "$fields" > "$_f"
    printf '%s' "$views"  > "$_v"
    printf '%s' "$items"  > "$_i"

    jq -n \
      --slurpfile proj   "$_p" \
      --slurpfile fields "$_f" \
      --slurpfile views  "$_v" \
      --slurpfile items  "$_i" \
      --argjson number "$number" \
      --arg     ts     "$(now)" \
      '{
        source_number: $number,
        title:         $proj[0].title,
        status:        "exported",
        exported_at:   $ts,
        target_number: null,
        target_id:     null,
        imported_at:   null,
        project:       $proj[0],
        fields:        $fields[0],
        views:         $views[0],
        items:         $items[0]
      }' > "$_rec"

    jq --argjson n "$number" --slurpfile rec "$_rec" \
      'def r: $rec[0];
       if (.items | map(select(.source_number == $n)) | length) > 0
       then .items = [.items[] | if .source_number == $n then
              # preserve any import progress already recorded for this project
              # (target_id is the authoritative idempotency marker — must survive re-export)
              . as $old | r
              | .target_number = $old.target_number
              | .target_id     = ($old.target_id // null)
              | .imported_at   = $old.imported_at
              | .status        = (if ($old.target_id // null) != null then "imported" else "exported" end)
            else . end]
       else .items += [r]
       end' \
      "$STATE_FILE" > "$_st" && mv "$_st" "$STATE_FILE"
    rm -f "$_p" "$_f" "$_v" "$_i" "$_rec" "$_st"

    exported=$((exported + 1))
    if (( exported % 5 == 0 )) && [[ "$DRY_RUN" -eq 0 ]]; then
      state_split_if_needed "$STATE_FILE"
      commit_state "mirror: export checkpoint $exported projects [skip ci]"
      state_unsplit "$STATE_FILE"
    fi
    pause 0.5
  done < <(echo "$projects" | jq -c '.[]')

  state_update_stats "$STATE_FILE"
  state_split_if_needed "$STATE_FILE"

  log "Stage 15 complete (export) — projects=$exported draft-issues=$draft_total"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    commit_state "mirror: export stage 15 (projects: $exported, draft-issues: $draft_total) [skip ci]"
  fi
}

# ===========================================================================
# IMPORT driver
# ===========================================================================
_run_import() {
  state_unsplit "$STATE_FILE"
  if [[ ! -f "$STATE_FILE" ]]; then
    warn "No projects snapshot at $STATE_FILE — run MIRROR_MODE=export first. Nothing to import."
    return 0
  fi

  local project_count
  project_count="$(jq '.items | length' "$STATE_FILE" 2>/dev/null || echo 0)"
  log "Importing $project_count project(s) into $TARGET_ORG (best-effort; manual report for the rest)"
  if [[ "$project_count" -eq 0 ]]; then
    log "Stage 15 complete (import) — 0 projects in snapshot"
    return 0
  fi

  # Resolve target org node ID once.
  local owner_id=""
  if [[ "$DRY_RUN" -eq 0 ]]; then
    owner_id="$(_gql_target_org_id "$TARGET_ORG")"
    if [[ -z "$owner_id" ]]; then
      err "Could not resolve target org '$TARGET_ORG' node ID — check GH_TOKEN has 'project' scope and org access. Aborting import."
      return 1
    fi
  fi

  # Begin the manual-steps report (covers everything the API can't do).
  # Skipped in dry-run: dry-run must not mutate disk (and would produce an empty
  # report anyway, since the per-project loop short-circuits before writing).
  [[ "$DRY_RUN" -eq 0 ]] && _manual_report_begin "$project_count"

  local imported=0 fields_made=0 drafts_made=0
  while IFS= read -r rec; do
    local snum title desc tgt_id tgt_existing
    snum="$(echo "$rec"  | jq -r '.source_number')"
    title="$(echo "$rec" | jq -r '.project.title // .title // "Untitled project"')"
    desc="$(echo "$rec"  | jq -r '.project.shortDescription // ""')"
    # target_id (node ID) is the authoritative idempotency marker — it is set
    # immediately after a successful create. target_number is informational and
    # may legitimately be 0, so it must NOT be the dedup key (BUG-E).
    tgt_id="$(echo "$rec" | jq -r '.target_id // empty')"
    tgt_existing="$(echo "$rec" | jq -r '.target_number // empty')"

    # Idempotency: skip projects already imported (recorded in local state).
    if [[ -n "$tgt_id" && "$tgt_id" != "null" ]]; then
      log "  Project '$title' already imported (#${tgt_existing:-?}) — skipping (append manual notes only)"
      [[ "$DRY_RUN" -eq 0 ]] && _manual_report_project "$rec" "$tgt_existing"
      continue
    fi

    if dry_run_skip "create project '$title' in $TARGET_ORG + fields + draft issues"; then
      imported=$((imported + 1)); continue
    fi

    # ---- 1. Create the project ----
    local created pid pnum
    created="$(_gql_create_project "$owner_id" "$title" "$desc")" || created=""
    if [[ -z "$created" ]]; then
      warn "  Failed to create project '$title' — recording for manual creation"
      _manual_report_project "$rec" ""
      continue
    fi
    pid="${created%%$'\t'*}"
    pnum="${created##*$'\t'}"
    ok "  Created project '$title' → #$pnum in $TARGET_ORG"

    # Persist the idempotency marker IMMEDIATELY — before fields/drafts. The node
    # id (pid) always exists on a successful create; recording it now means an
    # interruption during field/draft creation will NOT recreate the project on
    # the next run (which would duplicate it — projects have no body marker to
    # dedup against, unlike issues/PRs). BUG-B fix.
    _mark_project_imported "$snum" "$pnum" "$pid"

    # ---- 2. Recreate supported custom fields ----
    # GitHub auto-creates a default "Status" single-select field on every new
    # project; skip a same-named field to avoid a duplicate-name error.
    while IFS= read -r fld; do
      [[ -z "$fld" ]] && continue
      local fname ftype
      fname="$(echo "$fld" | jq -r '.name')"
      ftype="$(echo "$fld" | jq -r '.dataType // empty')"
      case "$ftype" in
        TEXT|NUMBER|DATE|SINGLE_SELECT) ;;
        *) continue ;;   # ITERATION + unknown → manual (reported below)
      esac
      # Skip GitHub's built-in fields that already exist on a fresh project.
      case "$fname" in
        Title|Assignees|Status|Labels|Linked\ pull\ requests|Milestone|Repository|Reviewers) continue ;;
      esac
      local opts new_fid
      opts="$(echo "$fld" | jq -c '.options // []')"
      new_fid="$(_gql_create_field "$pid" "$fname" "$ftype" "$opts")" || new_fid=""
      if [[ -n "$new_fid" ]]; then
        fields_made=$((fields_made + 1))
      else
        warn "    Field '$fname' ($ftype) could not be created — see manual report"
      fi
    done < <(echo "$rec" | jq -c '.fields[]? | select(.name != null)')

    # ---- 3. Recreate draft issues (title + body) ----
    while IFS= read -r it; do
      [[ -z "$it" ]] && continue
      local dtitle dbody
      dtitle="$(echo "$it" | jq -r '.content.title // "Untitled"')"
      dbody="$(echo "$it" | jq -r '.content.body // ""')"
      local item_id
      item_id="$(_gql_add_draft "$pid" "$dtitle" "$dbody")" || item_id=""
      [[ -n "$item_id" ]] && drafts_made=$((drafts_made + 1)) || \
        warn "    Draft issue '$dtitle' could not be created — see manual report"
    done < <(echo "$rec" | jq -c '.items[]? | select(.content.__typename == "DraftIssue")')

    # ---- Append manual notes for this project (marker already persisted above) ----
    _manual_report_project "$rec" "$pnum"

    imported=$((imported + 1))
    if (( imported % 3 == 0 )) && [[ "$DRY_RUN" -eq 0 ]]; then
      state_split_if_needed "$STATE_FILE"
      commit_state "mirror: import checkpoint $imported projects [skip ci]"
      state_unsplit "$STATE_FILE"
    fi
    pause 0.5
  done < <(state_items "$STATE_FILE")

  [[ "$DRY_RUN" -eq 0 ]] && _manual_report_end

  state_update_stats "$STATE_FILE"
  state_split_if_needed "$STATE_FILE"

  log "Stage 15 complete (import) — projects=$imported fields=$fields_made draft-issues=$drafts_made"
  log "  Manual steps for views/iteration-fields/linked-items: $MANUAL_REPORT"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    commit_state "mirror: import stage 15 (projects: $imported) + manual report [skip ci]"
  fi
}

# _mark_project_imported <source_number> <target_number> <target_id>
# target_number defaults to 0 upstream (never empty); target_id is the node ID
# and is the authoritative idempotency marker. Both are passed as strings via
# --arg (NOT --argjson) so an unexpected empty value can never abort jq (BUG-A).
_mark_project_imported() {
  local snum="$1" tnum="$2" tid="${3:-}"
  state_update "$STATE_FILE" \
    '.items = [.items[] | if (.source_number|tostring) == $sn then
       .target_number = ($tn | tonumber? // 0)
       | .target_id = (if $tid == "" then null else $tid end)
       | .status = "imported"
       | .imported_at = $ts
     else . end]' \
    --arg sn "$snum" --arg tn "$tnum" --arg tid "$tid" --arg ts "$(now)"
}

# ===========================================================================
# Manual-import report (single file covering everything the API cannot do)
# ===========================================================================
_manual_report_begin() {
  local n="$1"
  {
    echo "# Projects V2 — manual import steps"
    echo
    echo "_Generated $(now) for target org **$TARGET_ORG** from $n exported project(s)._"
    echo
    echo "The import stage automatically recreated, where the GitHub API allows it:"
    echo "the **project**, its supported **custom fields** (text / number / date /"
    echo "single-select), and its **draft issues** (title + body)."
    echo
    echo "GitHub provides **no write API** for the items below, so they must be"
    echo "recreated by hand in the target org. Each project section lists exactly"
    echo "what to do, with the original source values to copy."
    echo
    echo "## How to use this document"
    echo
    echo "1. Open the target project (link in each section)."
    echo "2. Work through that project's checklist top to bottom."
    echo "3. Tick each box as you go; the source values are provided inline."
    echo
    echo "---"
  } > "$MANUAL_REPORT"
}

# _manual_report_project <record_json> <target_number|"">
_manual_report_project() {
  local rec="$1" tnum="$2"
  local title src_num
  title="$(echo "$rec" | jq -r '.project.title // .title // "Untitled"')"
  src_num="$(echo "$rec" | jq -r '.source_number')"

  {
    echo
    echo "## Project: ${title}"
    echo
    if [[ -n "$tnum" && "$tnum" != "null" ]]; then
      echo "- **Target project:** https://github.com/orgs/${TARGET_ORG}/projects/${tnum}"
    else
      echo "- **Target project:** _NOT created automatically — create it manually first_ (org → Projects → New project)."
    fi
    echo "- **Source project #${src_num}:** $(echo "$rec" | jq -r '.project.url // "n/a"')"

    # ---- README (no API) ----
    local readme
    readme="$(echo "$rec" | jq -r '.project.readme // ""')"
    if [[ -n "$readme" && "$readme" != "null" ]]; then
      echo
      echo "### [ ] Set the project README"
      echo "Project → ⋯ → **Settings** → paste the README below:"
      echo
      echo '```markdown'
      echo "$readme"
      echo '```'
    fi

    # ---- Iteration fields (no stable create API) ----
    local iter_fields
    iter_fields="$(echo "$rec" | jq -c '[.fields[]? | select(.dataType == "ITERATION")]')"
    if [[ "$(echo "$iter_fields" | jq 'length')" -gt 0 ]]; then
      echo
      echo "### [ ] Recreate ITERATION fields (not creatable via API)"
      echo "For each iteration field below: Project → Settings → **+ New field** →"
      echo "type **Iteration**, then add the listed iterations (name + start date + duration in days)."
      echo
      while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        local fname dur startday
        fname="$(echo "$f" | jq -r '.name')"
        dur="$(echo "$f" | jq -r '.configuration.duration // "?"')"
        startday="$(echo "$f" | jq -r '.configuration.startDay // "?"')"
        echo "- **Field \"${fname}\"** (default duration ${dur} days, start day ${startday}):"
        echo "$f" | jq -r '
          (.configuration.iterations + (.configuration.completedIterations // []))[]?
          | "    - \(.title)  — start \(.startDate), \(.duration) day(s)"' 2>/dev/null || true
      done < <(echo "$iter_fields" | jq -c '.[]')
    fi

    # ---- Views / dashboards (no API) ----
    local views
    views="$(echo "$rec" | jq -c '.views // []')"
    if [[ "$(echo "$views" | jq 'length')" -gt 0 ]]; then
      echo
      echo "### [ ] Recreate views / dashboards (not creatable via API)"
      echo "A new project starts with one default view. For each source view below,"
      echo "create/rename a view (tab → **+ New view**), set its layout, and re-apply"
      echo "the filter / grouping / sorting shown:"
      echo
      while IFS= read -r v; do
        [[ -z "$v" ]] && continue
        local vname vlayout vfilter
        vname="$(echo "$v" | jq -r '.name // "View"')"
        vlayout="$(echo "$v" | jq -r '.layout // "TABLE_LAYOUT"')"
        vfilter="$(echo "$v" | jq -r '.filter // ""')"
        echo "- **\"${vname}\"** — layout: \`${vlayout}\`"
        [[ -n "$vfilter" && "$vfilter" != "null" ]] && echo "    - filter: \`${vfilter}\`"
      done < <(echo "$views" | jq -c '.[]')
    fi

    # ---- Linked repo issues/PRs (numbers differ in target) ----
    local linked
    linked="$(echo "$rec" | jq -c '[.items[]? | select(.content.__typename == "Issue" or .content.__typename == "PullRequest")]')"
    local lcount
    lcount="$(echo "$linked" | jq 'length')"
    if [[ "$lcount" -gt 0 ]]; then
      echo
      echo "### [ ] Re-add ${lcount} linked issue/PR item(s)"
      echo "These items pointed to repository issues/PRs in the source org. The"
      echo "mirrored copies exist in the target with DIFFERENT numbers, so re-add"
      echo "them by searching each in the target project (**+ Add item**). Source refs:"
      echo
      while IFS= read -r it; do
        [[ -z "$it" ]] && continue
        echo "$it" | jq -r '"    - \(.content.repository.nameWithOwner)#\(.content.number) — \(.content.title)"' 2>/dev/null || true
      done < <(echo "$linked" | jq -c '.[]')
    fi

    echo
    echo "---"
  } >> "$MANUAL_REPORT"
}

_manual_report_end() {
  {
    echo
    echo "## Not covered by the GitHub API at all"
    echo
    echo "- **Insights / charts** — recreate from each project's Insights tab."
    echo "- **Built-in workflows** (auto-archive, auto-add, item auto-set) — re-enable"
    echo "  under Project → ⋯ → **Workflows**."
    echo "- **Field values on linked (non-draft) items** — set after re-adding the items."
    echo "- **Status updates / project activity history** — not exportable."
  } >> "$MANUAL_REPORT"
}

# ---------------------------------------------------------------------------
main() {
  check_dry_run "$@"
  preflight

  log "Stage 15 — projects starting (mode=$MIRROR_MODE)"

  if in_import; then
    _run_import
    return 0
  fi
  if reads_source; then
    _run_export
    return 0
  fi
  warn "Stage 15: nothing to do in mode=$MIRROR_MODE"
}

main "$@"
