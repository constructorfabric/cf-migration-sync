#!/usr/bin/env bash
# mirror/tools/find-duplicates.sh
#
# Find (and optionally close) duplicate issues/PRs in the target org that were
# created by an interrupted migration run. A "duplicate" means two or more target
# items carry the same <!-- cf-mirror(-pr): ORG/REPO#N --> body marker.
#
# Strategy: the item with the LOWEST target issue number is kept (first-created).
# All later duplicates are CLOSED with an explanatory comment. Items are never
# permanently deleted — GitHub does not expose issue deletion via the API.
#
# Also handles PR-as-issue duplication: when a PR that could not be created as
# a real GitHub PR was created as an issue fallback (both carry cf-mirror-pr:
# markers), they are treated identically to any other duplicate pair.
#
# Output files:
#   state/.duplicates-report.json   Full report with clickable links (every run)
#   stdout                          TSV: REPO  SOURCE#  KEPT_URL  DUPLICATE_URLS
#   stderr                          Human-readable progress log
#
# Usage:
#   TARGET_ORG=constructorfabric GH_TOKEN=xxx \
#   ./mirror/tools/find-duplicates.sh [--repo REPO] [--remove] [--dry-run]
#
#   --repo REPO   Only scan this repo (default: all repos in TARGET_ORG)
#   --remove      Close duplicate items (default: report only)
#   --dry-run     Print what would happen; make no changes

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
ONLY_REPO=""
DO_REMOVE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)    ONLY_REPO="$2"; shift 2 ;;
    --remove)  DO_REMOVE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help)
      sed -n '/^# Usage:/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
      exit 0 ;;
    *) err "Unknown argument: $1. Use --help for usage."; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
if [[ -z "${TARGET_ORG:-}" ]]; then
  err "TARGET_ORG is not set. Example:
  TARGET_ORG=constructorfabric GH_TOKEN=ghp_... ./mirror/tools/find-duplicates.sh"
  exit 1
fi
if [[ -z "${GH_TOKEN:-}" ]]; then
  err "GH_TOKEN is not set. Example:
  TARGET_ORG=constructorfabric GH_TOKEN=ghp_... ./mirror/tools/find-duplicates.sh"
  exit 1
fi
export MIRROR_MODE="${MIRROR_MODE:-full}"

# Derive SOURCE_ORG from state meta if not set — needed to build source URLs.
if [[ -z "${SOURCE_ORG:-}" ]]; then
  for _sf in "$REPO_ROOT"/state/prs/*.yaml "$REPO_ROOT"/state/issues/*.yaml; do
    [[ -f "$_sf" ]] || continue
    _so="$(jq -r '.meta.source_org // empty' "$_sf" 2>/dev/null || true)"
    if [[ -n "$_so" ]]; then SOURCE_ORG="$_so"; break; fi
  done
fi
[[ -z "${SOURCE_ORG:-}" ]] && SOURCE_ORG="(unknown-source-org)"

REPORT_FILE="${REPO_ROOT}/state/.duplicates-report.json"
mkdir -p "$(dirname "$REPORT_FILE")"

log "find-duplicates: TARGET_ORG=$TARGET_ORG SOURCE_ORG=$SOURCE_ORG remove=$DO_REMOVE dry_run=$DRY_RUN"

# ---------------------------------------------------------------------------
# Build repo list
# ---------------------------------------------------------------------------
repos=()
if [[ -n "$ONLY_REPO" ]]; then
  repos=( "$ONLY_REPO" )
else
  log "Fetching repo list from $TARGET_ORG..."
  while IFS= read -r r; do
    [[ -n "$r" ]] && repos+=( "$r" )
  done < <(
    gh api "orgs/$TARGET_ORG/repos?per_page=100" --paginate 2>/dev/null \
    | jq -rs '[.[] | select(type=="array") | .[] | select(type=="object") | .name] | .[]' \
    2>/dev/null || true
  )
fi

if [[ ${#repos[@]} -eq 0 ]]; then
  warn "No repos found in $TARGET_ORG — nothing to scan."
  exit 0
fi
log "Scanning ${#repos[@]} repo(s) for duplicate cf-mirror items..."

# ---------------------------------------------------------------------------
# Scan each repo — build report JSON and TSV
# ---------------------------------------------------------------------------
total_dups=0
total_repos_affected=0
report_entries="[]"   # accumulates JSON objects for the final report

printf '# REPO\tSOURCE_TYPE#NUM\tKEPT_URL\tDUPLICATE_URLS\n'

for repo in "${repos[@]}"; do
  log "  Scanning $repo..."

  repo_raw=""
  repo_raw="$(gh api "repos/$TARGET_ORG/$repo/issues?state=all&per_page=100" \
    --paginate 2>/dev/null)" || repo_raw=""

  if [[ -z "$repo_raw" ]]; then
    warn "  Could not fetch issues for $repo — skipping"
    continue
  fi

  # Build (tgt, mtype, src, tgt_url, tgt_state) for every cf-mirror item.
  # RC-8 two-level paginate select; jq capture uses ?<name>.
  # Both real GitHub PRs and PR-fallback issues carry cf-mirror-pr: markers —
  # we detect them identically (handles PR-as-issue duplicates, see comment above).
  pairs="$(printf '%s' "$repo_raw" | jq -rs --arg torg "$TARGET_ORG" --arg repo "$repo" '
    [.[] | select(type=="array") | .[] | select(type=="object")
     | select((.body // "") | test("cf-mirror"; ""))
     | {
         tgt:      .number,
         tgt_url:  ("https://github.com/" + $torg + "/" + $repo + "/issues/" + (.number | tostring)),
         tgt_kind: (if .pull_request then "pr" else "issue" end),
         mtype:    (if (.body | test("cf-mirror-pr:"; "")) then "pr" else "issue" end),
         src:      (
           .body
           | try (capture("cf-mirror[^:]*: [^/]+/[^#]+#(?<n>[0-9]+)") | .n | tonumber)
           catch null
         ),
         src_repo: (
           .body
           | try (capture("cf-mirror[^:]*: [^/]+/(?<r>[^#]+)#") | .r)
           catch null
         )
       }
     | select(.src != null)
    ]
  ' 2>/dev/null || echo '[]')"

  # Group by (mtype+src) — find groups with more than one target number.
  dup_groups="$(printf '%s' "$pairs" | jq -r '
    group_by(.mtype + ":" + (.src | tostring))
    | map(select(length > 1))
    | .[]
    | {
        src:      .[0].src,
        src_repo: .[0].src_repo,
        mtype:    .[0].mtype,
        items:    (sort_by(.tgt))
      }
  ' 2>/dev/null || true)"

  [[ -z "$dup_groups" ]] && continue
  total_repos_affected=$(( total_repos_affected + 1 ))

  while IFS= read -r grp; do
    [[ -z "$grp" ]] && continue

    src_num="$(  echo "$grp" | jq -r '.src')"
    src_repo="$( echo "$grp" | jq -r '.src_repo // ""')"
    mtype="$(    echo "$grp" | jq -r '.mtype')"
    kept_tgt="$( echo "$grp" | jq -r '.items[0].tgt')"
    kept_url="$( echo "$grp" | jq -r '.items[0].tgt_url')"
    dup_count="$(echo "$grp" | jq -r '.items[1:] | length')"

    # Source URL (link to original in source org)
    src_url=""
    if [[ "$mtype" == "pr" ]]; then
      src_url="https://github.com/${SOURCE_ORG}/${src_repo:-$repo}/pull/${src_num}"
    else
      src_url="https://github.com/${SOURCE_ORG}/${src_repo:-$repo}/issues/${src_num}"
    fi

    # Build array of duplicate entries
    dup_entries="$(echo "$grp" | jq -c '[.items[1:] | .[] | {tgt: .tgt, url: .tgt_url, kind: .tgt_kind}]')"
    dup_urls="$(  echo "$grp" | jq -r '.items[1:] | map(.tgt_url) | join(" ")')"

    total_dups=$(( total_dups + dup_count ))

    # --- Accumulate report entry ---
    report_entry="$(jq -n \
      --arg repo      "$repo" \
      --arg mtype     "$mtype" \
      --argjson src   "$src_num" \
      --arg src_url   "$src_url" \
      --argjson kept  "$kept_tgt" \
      --arg kept_url  "$kept_url" \
      --argjson dups  "$dup_entries" \
      '{repo:$repo, type:$mtype, source_number:$src, source_url:$src_url,
        kept_target:$kept, kept_url:$kept_url,
        duplicates:$dups}')"
    report_entries="$(printf '%s\n%s' "$report_entries" "$report_entry" \
      | jq -s '.[0] + [.[1:][]]')"

    warn "  DUPLICATE: $repo ${mtype}#${src_num} — keep #${kept_tgt} ($kept_url), source: $src_url"
    printf '%s\t%s#%s\t%s\t%s\n' "$repo" "$mtype" "$src_num" "$kept_url" "$dup_urls"

    if [[ "$DO_REMOVE" -eq 1 ]]; then
      while IFS= read -r dup_item; do
        [[ -z "$dup_item" ]] && continue
        dup_tgt="$(echo "$dup_item" | jq -r '.tgt')"
        dup_url="$(echo "$dup_item" | jq -r '.url')"
        dup_kind="$(echo "$dup_item" | jq -r '.kind')"

        if [[ "$DRY_RUN" -eq 1 ]]; then
          log "  [dry-run] Would close ${dup_kind} #${dup_tgt} ($dup_url)"
          log "             ↳ kept:   ${kept_url}"
          log "             ↳ source: ${src_url}"
        else
          comment_body="🤖 **Closing duplicate** — this ${dup_kind} was created twice during an interrupted migration run.

| | Link |
|---|---|
| **Canonical copy (kept)** | ${kept_url} |
| **Original source** | ${src_url} |

This duplicate (#${dup_tgt}) is being closed automatically by \`find-duplicates.sh\`.
The canonical copy has the lower issue/PR number and was created first."
          printf '%s' "$comment_body" | jq -Rs '{"body":.}' \
            | gh api "repos/$TARGET_ORG/$repo/issues/$dup_tgt/comments" \
                --method POST --input /dev/stdin 2>/dev/null \
            || warn "  Failed to post comment on #$dup_tgt"
          gh api "repos/$TARGET_ORG/$repo/issues/$dup_tgt" \
            --method PATCH -f state="closed" 2>/dev/null \
          || warn "  Failed to close #$dup_tgt"
          ok "  Closed duplicate ${dup_kind} #$dup_tgt ($dup_url)"
        fi
      done < <(printf '%s' "$dup_entries" | jq -c '.[]')
    fi

  done < <(printf '%s' "$dup_groups" | jq -c '.')

done

# ---------------------------------------------------------------------------
# Write report file
# ---------------------------------------------------------------------------
run_at="$(now)"
jq -n \
  --arg run_at       "$run_at" \
  --arg target_org   "$TARGET_ORG" \
  --arg source_org   "$SOURCE_ORG" \
  --argjson removed  "$DO_REMOVE" \
  --argjson dry_run  "$DRY_RUN" \
  --argjson total    "$total_dups" \
  --argjson entries  "$report_entries" \
  '{run_at: $run_at, target_org: $target_org, source_org: $source_org,
    removed: ($removed == 1), dry_run: ($dry_run == 1),
    total_duplicates: $total, duplicates: $entries}' \
  > "$REPORT_FILE" 2>/dev/null || true
log "Report written to $REPORT_FILE"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
log "---"
if [[ "$total_dups" -eq 0 ]]; then
  log "No duplicates found across ${#repos[@]} repo(s). ✓"
else
  log "Found $total_dups duplicate(s) across $total_repos_affected repo(s)."
  log "Full report with links: $REPORT_FILE"
  if [[ "$DO_REMOVE" -eq 0 ]]; then
    log "Re-run with --remove to close duplicates (--dry-run to preview first)."
  elif [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] No changes made."
  else
    log "Duplicates closed. Re-run without --remove to verify."
  fi
fi
