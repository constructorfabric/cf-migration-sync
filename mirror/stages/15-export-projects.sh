#!/usr/bin/env bash
# mirror/stages/15-export-projects.sh
# Deep export (backup) of all organization Projects V2 — the modern GitHub
# Projects (tables / boards / roadmaps), including their dashboards (views),
# custom fields, items, and DRAFT ISSUES (org-level issues not linked to any repo).
#
# Why a dedicated stage (and why export-only):
#   * Projects V2 is GraphQL-only (no REST). Stage 09 inventories projects
#     shallowly (title/url/number); this stage captures the FULL configuration.
#   * GitHub provides NO write API for project VIEWS / dashboards (board/table/
#     roadmap layouts, their filters, grouping, sorting). They cannot be
#     recreated programmatically. Combined with the operator's choice, this stage
#     is EXPORT-ONLY: a complete, faithful JSON snapshot for backup / record /
#     manual rebuild. There is no import side.
#
# What is captured per project:
#   - project: id, number, title, shortDescription, readme, public, closed,
#              createdAt, updatedAt, creator, url
#   - fields:  every custom field (text/number/date/single-select/iteration),
#              including single-select options and iteration configurations
#   - views:   every view (dashboard) with layout, filter, group/sort settings
#              (captured for the record; GitHub has no API to recreate these)
#   - items:   every item with its field values; for items backed by a repo
#              issue/PR the content reference (repo + number + url) is recorded;
#              DRAFT ISSUES (title + body, not tied to a repo) are captured in full
#
# State file: state/projects.yaml   (split automatically if it exceeds the limit)
#
# Modes (MIRROR_MODE):
#   export — fetch + serialize everything (the only meaningful mode here).
#   full   — treated as export (still source-read only; never writes target).
#   import — NO-OP: GitHub cannot recreate views/dashboards via API, so this
#            stage intentionally has no import side. A clear message is logged
#            and the captured snapshot is left for manual reference.
#
# Requires a token with read:project scope on the SOURCE org (GH_TOKEN_SOURCE).
#
# Usage:
#   SOURCE_ORG=cyberfabric GH_TOKEN_SOURCE=xxx \
#   MIRROR_MODE=export \
#   ./mirror/stages/15-export-projects.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

STATE_FILE="$REPO_ROOT/state/projects.yaml"

# Page sizes for the paginated GraphQL sub-collections.
PROJECTS_PAGE=20
FIELDS_PAGE=50
VIEWS_PAGE=50
ITEMS_PAGE=50

# ---------------------------------------------------------------------------
# _gql_projects_page <org> <after>
# Fetch one page of org projectsV2 (lightweight: id/number/title + pageInfo).
# <after> is a GraphQL cursor or the literal "null" for the first page.
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

# _gql_fields <project_id> — all custom fields for a project (one page; field
# counts are small). Captures single-select options and iteration config.
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

# _gql_views <project_id> — all views (dashboards) for a project.
# layout/filter/grouping/sorting captured for the record (no recreate API).
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

# _gql_items_page <project_id> <after> — one page of items with field values
# and content reference. Draft issues are captured via the DraftIssue content type.
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

# ---------------------------------------------------------------------------
main() {
  check_dry_run "$@"
  preflight

  log "Stage 15 — export-projects starting (mode=$MIRROR_MODE)"

  # Import is a deliberate no-op: views/dashboards have no GitHub write API, so
  # there is nothing this stage can recreate. The snapshot is reference-only.
  if in_import; then
    log "Stage 15 is export-only (GitHub has no API to recreate project views/dashboards)."
    log "  The exported snapshot at state/projects.yaml is for backup / manual rebuild."
    return 0
  fi

  # full and export both only read the source here; guard accordingly.
  if ! reads_source; then
    warn "Stage 15 only reads the source org; nothing to do in mode=$MIRROR_MODE"
    return 0
  fi

  # Reassemble any prior split parts before we overwrite the snapshot.
  state_unsplit "$STATE_FILE"
  state_init "$STATE_FILE" "15-export-projects"

  # ---- Enumerate all org projects (paginated) -----------------------------
  log "Fetching Projects V2 from $SOURCE_ORG..."
  local projects="[]"
  local after="null"
  while :; do
    local page
    page="$(_gql_projects_page "$SOURCE_ORG" "$after")" || page=""
    if [[ -z "$page" ]]; then
      warn "  Projects query returned nothing — check that GH_TOKEN_SOURCE has read:project scope"
      break
    fi
    # Surface GraphQL errors (e.g. missing scope) instead of silently exporting nothing.
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

  # ---- Deep-export each project -------------------------------------------
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

    # Upsert this project's full record into the state file (keyed by project number).
    # All large JSON goes to jq via --slurpfile (file), never as an OS arg (RC-6).
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
        project:       $proj[0],
        fields:        $fields[0],
        views:         $views[0],
        items:         $items[0]
      }' > "$_rec"

    jq --argjson n "$number" --slurpfile rec "$_rec" \
      'def r: $rec[0];
       if (.items | map(select(.source_number == $n)) | length) > 0
       then .items = [.items[] | if .source_number == $n then r else . end]
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

main "$@"
