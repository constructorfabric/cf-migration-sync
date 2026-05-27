#!/usr/bin/env bash
# mirror/lib/common.sh — shared functions for all mirror stages
# Source this file at the top of each stage script:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/../lib/common.sh"

set -euo pipefail

# ---------------------------------------------------------------------------
# Colour codes
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log() {
  echo -e "${CYAN}[$(now)]${RESET} $*" >&2
}

ok() {
  echo -e "${GREEN}[$(now)] OK${RESET} $*" >&2
}

warn() {
  echo -e "${YELLOW}[$(now)] WARN${RESET} $*" >&2
}

err() {
  echo -e "${RED}[$(now)] ERROR${RESET} $*" >&2
}

# ---------------------------------------------------------------------------
# Timing / rate-limit helpers
# ---------------------------------------------------------------------------
pause() {
  local secs="${1:-0.3}"
  sleep "$secs"
}

# Remove a rewrite-crossrefs.yaml entry so stage 07 re-processes the body
# on its next run.  Call after any PATCH that replaces a mirrored issue/PR body.
_clear_crossref_record() {
  local repo_name="$1"
  local tgt_number="$2"
  local crossrefs_file="${REPO_ROOT}/state/rewrite-crossrefs.yaml"
  [[ -f "$crossrefs_file" ]] || return 0
  local tmp
  tmp="$(mktemp)"
  jq --arg r "$repo_name" --argjson n "$tgt_number" \
    '.items = [.items[] | select(not (.repo == $r and .target_number == $n))]' \
    "$crossrefs_file" > "$tmp" && mv "$tmp" "$crossrefs_file" || rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# GitHub API helpers
# ---------------------------------------------------------------------------
# ghsrc — call GitHub API authenticated as the SOURCE org token
ghsrc() {
  GH_TOKEN="${GH_TOKEN_SOURCE}" gh "$@"
}

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
preflight() {
  local missing=0

  for cmd in gh git jq; do
    if ! command -v "$cmd" &>/dev/null; then
      err "Required command not found: $cmd"
      missing=1
    fi
  done

  if [[ -z "${GH_TOKEN:-}" ]]; then
    err "GH_TOKEN is not set (target org token)"
    missing=1
  fi

  if [[ -z "${GH_TOKEN_SOURCE:-}" ]]; then
    err "GH_TOKEN_SOURCE is not set (source org token)"
    missing=1
  fi

  if [[ -z "${SOURCE_ORG:-}" ]]; then
    err "SOURCE_ORG is not set"
    missing=1
  fi

  if [[ -z "${TARGET_ORG:-}" ]]; then
    err "TARGET_ORG is not set"
    missing=1
  fi

  if [[ "$missing" -ne 0 ]]; then
    err "Preflight checks failed. Exiting."
    exit 1
  fi

  config_load
  ok "Preflight passed (SOURCE_ORG=$SOURCE_ORG, TARGET_ORG=$TARGET_ORG)"
}

# ---------------------------------------------------------------------------
# State file helpers
# ---------------------------------------------------------------------------

# state_read — read a state file, return '{}' if missing
state_read() {
  local file="$1"
  if [[ -f "$file" ]]; then
    cat "$file"
  else
    echo '{}'
  fi
}

# state_init — create state file with meta envelope if it doesn't exist
# Usage: state_init <file> <stage-name>
state_init() {
  local file="$1"
  local stage="$2"
  local ts
  ts="$(now)"

  if [[ -f "$file" ]]; then
    # File exists — just update last_run_at
    local tmp
    tmp="$(mktemp)"
    jq --arg ts "$ts" '.meta.last_run_at = $ts' "$file" > "$tmp"
    mv "$tmp" "$file"
    return 0
  fi

  # Create parent directory if needed
  mkdir -p "$(dirname "$file")"

  jq -n \
    --arg stage   "$stage" \
    --arg src     "${SOURCE_ORG}" \
    --arg tgt     "${TARGET_ORG}" \
    --arg ts      "$ts" \
    '{
      meta: {
        stage:        $stage,
        source_org:   $src,
        target_org:   $tgt,
        first_run_at: $ts,
        last_run_at:  $ts
      },
      items: [],
      stats: { total: 0, synced: 0, pending: 0, failed: 0 }
    }' > "$file"
}

# state_update — apply a jq filter to a state file atomically
# Usage: state_update <file> <jq-filter> [jq-args...]
state_update() {
  local file="$1"
  local filter="$2"
  shift 2

  local tmp
  tmp="$(mktemp)"

  # Pass remaining args as extra jq args
  jq "$@" "$filter" "$file" > "$tmp"
  mv "$tmp" "$file"
}

# state_update_stats — recompute stats from items array
# Expects items to have a "status" field
state_update_stats() {
  local file="$1"
  local tmp
  tmp="$(mktemp)"
  jq '
    .stats.total   = (.items | length) |
    .stats.synced  = (.items | map(select(.status == "synced" or .status == "mirrored" or .status == "invited" or .status == "accepted" or .status == "applied")) | length) |
    .stats.pending = (.items | map(select(.status == "pending")) | length) |
    .stats.failed  = (.items | map(select(.status == "failed")) | length)
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

# ---------------------------------------------------------------------------
# Git commit helper
# ---------------------------------------------------------------------------
# commit_state — stage state/ and validation-reports/, commit, push
# Usage: commit_state "commit message"
commit_state() {
  local msg="${1:-"mirror: update state [skip ci]"}"

  # Ensure we're in the repo root
  local repo_root
  repo_root="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -z "$repo_root" ]]; then
    warn "commit_state: could not find git root, skipping commit"
    return 0
  fi

  cd "$repo_root"

  git add mirror/state/ state/ validation-reports/ 2>/dev/null || true

  if git diff --cached --quiet; then
    log "commit_state: nothing to commit"
    return 0
  fi

  git -c user.name="github-actions[bot]" \
      -c user.email="github-actions[bot]@users.noreply.github.com" \
      commit --allow-empty -m "$msg"

  git push
  ok "commit_state: pushed — $msg"
}

# ---------------------------------------------------------------------------
# Dry-run helper
# ---------------------------------------------------------------------------
DRY_RUN=0

# ---------------------------------------------------------------------------
# Config helpers
# ---------------------------------------------------------------------------
# Populated by config_load (called from preflight).
MIRROR_CONFIG=""

# INVITE_MEMBERS — global mode flag derived from config.json invite_members.
#   1 = active migration / DR: invite members, apply assignees, sync team members
#   0 = backup / read-only mirror: skip all of the above
#
# Default 1 so scripts work even if config is partially written.
# RC-4: do NOT use "// true" — jq treats false as falsy and would discard it.
# Use explicit "== false" comparison instead.
INVITE_MEMBERS=1

# config_load — locate and validate mirror/config.json.
# Sets MIRROR_CONFIG and all global config-derived flags.
# Called automatically from preflight().
config_load() {
  local config_path="${REPO_ROOT}/mirror/config.json"
  if [[ ! -f "$config_path" ]]; then
    err "Mirror config not found: $config_path"
    exit 1
  fi
  if ! jq empty "$config_path" 2>/dev/null; then
    err "Mirror config is not valid JSON: $config_path"
    exit 1
  fi
  MIRROR_CONFIG="$config_path"

  # invite_members: explicit false → 0; anything else (true, missing) → 1.
  # RC-4: .invite_members == false is the only safe pattern for boolean presence.
  INVITE_MEMBERS="$(jq -r 'if (.invite_members == false) then "0" else "1" end' \
    "$config_path" 2>/dev/null || echo "1")"

  local invite_label
  invite_label="$([ "$INVITE_MEMBERS" -eq 1 ] && echo "true (active migration / DR mode)" || echo "false (backup / read-only mirror mode)")"
  log "Config loaded: $MIRROR_CONFIG"
  log "  invite_members = $invite_label"
}

check_dry_run() {
  for arg in "$@"; do
    if [[ "$arg" == "--dry-run" ]]; then
      DRY_RUN=1
      warn "DRY RUN mode — no API writes will be performed"
      return 0
    fi
  done
}

dry_run_skip() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] would execute: $*"
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Pagination helper — fetch all pages from a GitHub API endpoint
# ---------------------------------------------------------------------------
# gh_paginate <ghsrc|gh> <endpoint> [extra jq filter]
# Prints a JSON array of all items combined
gh_paginate() {
  local cmd="$1"   # "gh" or "ghsrc"
  local endpoint="$2"
  local filter="${3:-.}"

  local page=1
  local per_page=100
  local all="[]"

  while true; do
    local url="${endpoint}?per_page=${per_page}&page=${page}"
    local batch

    if [[ "$cmd" == "ghsrc" ]]; then
      batch="$(ghsrc api "$url" 2>/dev/null)" || batch='[]'
    else
      batch="$(gh api "$url" 2>/dev/null)" || batch='[]'
    fi

    # Normalize: extract first JSON value to guard against extra runner output (RC-3)
    batch="$(echo "$batch" | jq -rs '.[0] // []' 2>/dev/null)" || batch='[]'

    # If empty array or null, stop
    local count
    count="$(echo "$batch" | jq 'if type=="array" then length else 0 end' 2>/dev/null || echo 0)"
    if [[ "$count" -eq 0 ]]; then
      break
    fi

    all="$(echo "$all $batch" | jq -s 'add | map('"$filter"')')"
    page=$((page + 1))
  done

  echo "$all"
}
