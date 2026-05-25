#!/usr/bin/env bash
# mirror/stages/02-mirror-repos.sh
# Mirror all source org repos to the target org via git push --mirror.
# No state YAML needed — git itself tracks what's synced.
#
# Usage:
#   SOURCE_ORG=cyberfabric TARGET_ORG=constructorfabric \
#   GH_TOKEN=xxx GH_TOKEN_SOURCE=xxx \
#   ./mirror/stages/02-mirror-repos.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

TARGET_ORG="${TARGET_ORG:-constructorfabric}"

# Temp directory for bare clones
WORK_DIR="${TMPDIR:-/tmp}/mirror-repos-$$"

# ---------------------------------------------------------------------------
main() {
  check_dry_run "$@"
  preflight

  log "Stage 02 — mirror-repos starting"
  mkdir -p "$WORK_DIR"
  trap 'rm -rf "$WORK_DIR"' EXIT

  # ---- 1. Fetch all source repos ----------------------------------------
  log "Fetching source repos from $SOURCE_ORG..."
  local repos
  repos="$(gh_paginate ghsrc "orgs/$SOURCE_ORG/repos")"
  local total
  total="$(echo "$repos" | jq 'length')"
  log "Found $total repos in $SOURCE_ORG"

  local processed=0
  local success_count=0
  local failed_count=0

  while IFS= read -r repo; do
    local name
    name="$(echo "$repo" | jq -r '.name')"
    local private
    private="$(echo "$repo" | jq -r '.private')"
    local default_branch
    default_branch="$(echo "$repo" | jq -r '.default_branch // "main"')"

    processed=$((processed + 1))
    if (( processed % 10 == 0 )); then
      log "Progress: $processed/$total repos processed..."
    fi

    log "[$processed/$total] Mirroring $SOURCE_ORG/$name..."

    if dry_run_skip "mirror $SOURCE_ORG/$name -> $TARGET_ORG/$name"; then
      success_count=$((success_count + 1))
      continue
    fi

    # ---- Create target repo if it doesn't exist -------------------------
    local target_exists
    target_exists="$(gh api "repos/$TARGET_ORG/$name" 2>/dev/null | jq -r '.name // empty' || true)"

    if [[ -z "$target_exists" ]]; then
      log "Creating target repo $TARGET_ORG/$name (private=$private)..."
      gh api "orgs/$TARGET_ORG/repos" \
        --method POST \
        -f name="$name" \
        -f private="$private" \
        -f auto_init=false \
        2>/dev/null || {
          warn "Failed to create $TARGET_ORG/$name, skipping"
          failed_count=$((failed_count + 1))
          continue
        }
      pause 0.5
    fi

    # ---- Clone mirror from source ---------------------------------------
    local clone_dir="$WORK_DIR/$name.git"
    rm -rf "$clone_dir"

    local source_url="https://${GH_TOKEN_SOURCE}@github.com/${SOURCE_ORG}/${name}.git"
    local target_url="https://${GH_TOKEN}@github.com/${TARGET_ORG}/${name}.git"

    log "Cloning $SOURCE_ORG/$name (bare mirror)..."
    if ! git clone --mirror "$source_url" "$clone_dir" 2>/dev/null; then
      warn "Failed to clone $SOURCE_ORG/$name, skipping"
      failed_count=$((failed_count + 1))
      continue
    fi

    # ---- Push mirror to target ------------------------------------------
    log "Pushing mirror to $TARGET_ORG/$name..."
    cd "$clone_dir"

    # Set push remote
    git remote set-url --push origin "$target_url"

    # Attempt full mirror push first
    if git push --mirror 2>/dev/null; then
      ok "Mirrored $name successfully"
      success_count=$((success_count + 1))
    else
      warn "Mirror push failed for $name (likely refs/pull/* rejection), trying explicit refspecs..."

      # Fallback: unset mirror config and push explicit refspecs
      git config --unset remote.origin.mirror 2>/dev/null || true

      # Fetch all branch and tag refspecs explicitly
      local push_ok=1
      if ! git push origin '+refs/heads/*:refs/heads/*' 2>/dev/null; then
        warn "Failed to push branches for $name"
        push_ok=0
      fi
      if ! git push origin '+refs/tags/*:refs/tags/*' 2>/dev/null; then
        warn "Failed to push tags for $name (non-fatal)"
      fi

      if [[ "$push_ok" -eq 1 ]]; then
        ok "Mirrored $name (fallback refspecs)"
        success_count=$((success_count + 1))
      else
        failed_count=$((failed_count + 1))
      fi
    fi

    cd "$REPO_ROOT"
    rm -rf "$clone_dir"
    pause 0.5

  done < <(echo "$repos" | jq -c '.[]')

  log "Stage 02 complete — success=$success_count failed=$failed_count total=$total"
}

main "$@"
