#!/usr/bin/env bash
# _lib.sh — shared helpers for migration scripts
# Source this from every other script: source "$(dirname "$0")/_lib.sh"

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
export SOURCE_ORG="${SOURCE_ORG:-cyberfabric}"
export TARGET_ORG="${TARGET_ORG:-constructorfabric}"

# ── Token strategy ───────────────────────────────────────────────────────────
# GH_TOKEN_SOURCE — if set, used for ALL source-org API calls
# GH_TOKEN        — used for all target-org calls; also fallback if GH_TOKEN_SOURCE unset
ghsrc() {
  # Pipe env to subshell so we don't leak the token into any child process argv.
  # The gh cli reads GH_TOKEN / GH_TOKEN_SOURCE from env, so just set and run.
  if [ -n "${GH_TOKEN_SOURCE:-}" ]; then
    env GH_TOKEN="$GH_TOKEN_SOURCE" gh "$@"
  else
    env GH_TOKEN="${GH_TOKEN:-}" gh "$@"
  fi
}

# ── Logging ──────────────────────────────────────────────────────────────────
log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
ok()   { printf '\033[1;32m  ✓ %s\033[0m\n' "$*" >&2; }
warn() { printf '\033[1;33m  ! %s\033[0m\n' "$*" >&2; }
err()  { printf '\033[1;31m  ✗ %s\033[0m\n' "$*" >&2; }

# ── Preflight checks ─────────────────────────────────────────────────────────
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { err "Missing required command: $1"; exit 1; }
}

require_env() {
  if [ -z "${!1:-}" ]; then
    err "Required env var $1 is not set."
    err "Run: export $1=...  (see README)"
    exit 1
  fi
}

preflight() {
  require_cmd gh
  require_cmd git
  require_cmd jq
  require_env GH_TOKEN
  if [ -n "${GH_TOKEN_SOURCE:-}" ]; then
    log "Using GH_TOKEN_SOURCE for source-org calls (GH_TOKEN for target)"
  fi
}

# ── Repo listing (source org) ─────────────────────────────────────────────────
# Uses GH_TOKEN_SOURCE if set, otherwise falls back to GH_TOKEN.
list_source_repos() {
  ghsrc api "orgs/${SOURCE_ORG}/repos" --paginate --jq '.[].name' | sort
}

# ── Interactive helpers ──────────────────────────────────────────────────────
confirm() {
  local prompt="${1:-Continue?}"
  read -r -p "$prompt [y/N] " ans
  case "$ans" in
    y|Y|yes|YES) return 0 ;;
    *)           return 1 ;;
  esac
}

# ── Rate-limit gentle pacing ─────────────────────────────────────────────────
pause() { sleep "${1:-0.4}"; }
