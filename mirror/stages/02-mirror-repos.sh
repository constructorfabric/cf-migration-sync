#!/usr/bin/env bash
# mirror/stages/02-mirror-repos.sh
# Mirror all source org repos to the target org via git push.
#
# Modes (MIRROR_MODE):
#   full   — clone each source repo and push to target in one pass (default).
#   export — clone each source repo into a local gitignored folder
#            (mirror-clones/<repo>.git) and write a metadata manifest to
#            state/repos-manifest.json. NEVER contacts the target org.
#   import — read the manifest, create target repos, and push the previously
#            cloned bare repos to the target. NEVER contacts the source org.
#
# Unlike every other stage, stage 02 cannot serialize repo contents into JSON —
# the "serialized" form of a git repo IS a git repo, so export keeps real bare
# clones on disk (gitignored) and import replays them. Export and import for this
# stage therefore run on the same machine (or you copy mirror-clones/ across).
#
# Usage:
#   SOURCE_ORG=cyberfabric TARGET_ORG=constructorfabric \
#   GH_TOKEN=xxx GH_TOKEN_SOURCE=xxx \
#   MIRROR_MODE=full|export|import \
#   ./mirror/stages/02-mirror-repos.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

TARGET_ORG="${TARGET_ORG:-constructorfabric}"

# Persistent, gitignored working folder for bare clones. Shared by all three
# modes (full cleans each clone after push; export/import keep them).
CLONES_DIR="$REPO_ROOT/mirror-clones"
# Repo metadata manifest produced by export, consumed by import.
MANIFEST_FILE="$REPO_ROOT/state/repos-manifest.json"

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

# _clone_source_bare <name> — bare-clone a source repo into CLONES_DIR, then
# scrub the embedded source token from the clone's git config so no credential
# is persisted on disk. Returns non-zero if the clone fails (empty/unreachable).
#
# We use --bare instead of --mirror deliberately: --mirror fetches refs/pull/*
# (GitHub PR refs) which GitHub then rejects on push because refs/pull/* is a
# server-managed read-only namespace. --bare fetches only refs/heads/* and
# refs/tags/* — exactly what we want.
_clone_source_bare() {
  local name="$1"
  local clone_dir="$CLONES_DIR/$name.git"
  local source_url="https://${GH_TOKEN_SOURCE}@github.com/${SOURCE_ORG}/${name}.git"
  rm -rf "$clone_dir"
  if ! git clone --bare "$source_url" "$clone_dir" 2>/dev/null; then
    return 1
  fi
  # Remove the credentialed origin URL; leave a clean, token-free reference URL.
  git -C "$clone_dir" remote set-url origin \
    "https://github.com/${SOURCE_ORG}/${name}.git" 2>/dev/null || true
  return 0
}

# _create_target_repo_if_absent <name> <private> — create the target repo when
# it does not already exist. Returns non-zero only on a real creation failure.
_create_target_repo_if_absent() {
  local name="$1" private="$2"
  # gh api writes 404 error JSON to stdout even on failure, so check exit code
  # out-of-band (RC-5) rather than piping through jq.
  local target_exists
  target_exists="$(gh api "repos/$TARGET_ORG/$name" 2>/dev/null)" || target_exists=""
  if [[ -n "$target_exists" ]]; then
    return 0
  fi
  log "Creating target repo $TARGET_ORG/$name (private=$private)..."
  gh api "orgs/$TARGET_ORG/repos" \
    --method POST \
    -f name="$name" \
    -f private="$private" \
    -f auto_init=false \
    2>/dev/null || return 1
  pause 0.5
  return 0
}

# _push_clone_to_target <name> — push the local bare clone to the target org.
# The target URL (with token) is passed inline to `git push` so it is never
# written to the clone's persisted config. --prune removes branches/tags from
# target that were deleted in source. Explicit refspecs skip refs/pull/* and any
# other non-standard namespaces. Returns non-zero if the branch push fails.
_push_clone_to_target() {
  local name="$1"
  local clone_dir="$CLONES_DIR/$name.git"
  if [[ ! -d "$clone_dir" ]]; then
    warn "No local clone found for $name at $clone_dir — run export first"
    return 1
  fi
  local target_url="https://${GH_TOKEN}@github.com/${TARGET_ORG}/${name}.git"

  log "Pushing $name to $TARGET_ORG/$name..."
  local push_ok=1
  if ! git -C "$clone_dir" push --prune "$target_url" '+refs/heads/*:refs/heads/*' 2>/dev/null; then
    warn "Failed to push branches for $name"
    push_ok=0
  fi
  if ! git -C "$clone_dir" push --prune "$target_url" '+refs/tags/*:refs/tags/*' 2>/dev/null; then
    warn "Failed to push tags for $name (non-fatal)"
  fi
  [[ "$push_ok" -eq 1 ]]
}

# _load_excluded_repos — print newline-separated excluded repo names from config.
_load_excluded_repos() {
  jq -r '.stage_02_mirror_repos.exclude_repos[] // empty' \
    "$MIRROR_CONFIG" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Mode: full — clone source + push target in one pass (original behaviour)
# ---------------------------------------------------------------------------
_run_full() {
  log "Fetching source repos from $SOURCE_ORG..."
  local repos
  repos="$(gh_paginate ghsrc "orgs/$SOURCE_ORG/repos")"
  local total
  total="$(echo "$repos" | jq 'length')"
  log "Found $total repos in $SOURCE_ORG"

  local excluded_repos
  excluded_repos="$(_load_excluded_repos)"
  [[ -n "$excluded_repos" ]] && log "Excluded repos: $(echo "$excluded_repos" | tr '\n' ' ')"

  local processed=0 success_count=0 failed_count=0

  while IFS= read -r repo; do
    local name private
    name="$(echo "$repo" | jq -r '.name')"
    private="$(echo "$repo" | jq -r '.private')"

    processed=$((processed + 1))
    (( processed % 10 == 0 )) && log "Progress: $processed/$total repos processed..."

    if [[ -n "$excluded_repos" ]] && echo "$excluded_repos" | grep -qx "$name" 2>/dev/null; then
      log "[$processed/$total] Skipping excluded repo: $name"
      continue
    fi

    log "[$processed/$total] Mirroring $SOURCE_ORG/$name..."
    if dry_run_skip "mirror $SOURCE_ORG/$name -> $TARGET_ORG/$name"; then
      success_count=$((success_count + 1)); continue
    fi

    if ! _create_target_repo_if_absent "$name" "$private"; then
      warn "Failed to create $TARGET_ORG/$name, skipping"
      failed_count=$((failed_count + 1)); continue
    fi

    log "Cloning $SOURCE_ORG/$name..."
    if ! _clone_source_bare "$name"; then
      warn "Failed to clone $SOURCE_ORG/$name (empty repo or unreachable), skipping"
      failed_count=$((failed_count + 1)); continue
    fi

    if _push_clone_to_target "$name"; then
      ok "Mirrored $name"
      success_count=$((success_count + 1))
    else
      failed_count=$((failed_count + 1))
    fi

    rm -rf "$CLONES_DIR/$name.git"   # full mode does not retain clones
    pause 0.5
  done < <(echo "$repos" | jq -c '.[]')

  log "Stage 02 (full) complete — success=$success_count failed=$failed_count total=$total"
}

# ---------------------------------------------------------------------------
# Mode: export — clone source repos locally + write metadata manifest
# ---------------------------------------------------------------------------
_run_export() {
  log "Fetching source repos from $SOURCE_ORG..."
  local repos
  repos="$(gh_paginate ghsrc "orgs/$SOURCE_ORG/repos")"
  local total
  total="$(echo "$repos" | jq 'length')"
  log "Found $total repos in $SOURCE_ORG"

  local excluded_repos
  excluded_repos="$(_load_excluded_repos)"
  [[ -n "$excluded_repos" ]] && log "Excluded repos: $(echo "$excluded_repos" | tr '\n' ' ')"

  mkdir -p "$(dirname "$MANIFEST_FILE")"
  # Manifest envelope; repos[] is filled as we successfully clone each repo.
  local manifest_tmp
  manifest_tmp="$(mktemp)"
  jq -n --arg src "$SOURCE_ORG" --arg ts "$(now)" \
    '{meta:{source_org:$src, exported_at:$ts}, repos:[]}' > "$manifest_tmp"

  local processed=0 success_count=0 failed_count=0

  while IFS= read -r repo; do
    local name private default_branch
    name="$(echo "$repo" | jq -r '.name')"
    private="$(echo "$repo" | jq -r '.private')"
    default_branch="$(echo "$repo" | jq -r '.default_branch // "main"')"

    processed=$((processed + 1))
    (( processed % 10 == 0 )) && log "Progress: $processed/$total repos processed..."

    if [[ -n "$excluded_repos" ]] && echo "$excluded_repos" | grep -qx "$name" 2>/dev/null; then
      log "[$processed/$total] Skipping excluded repo: $name"
      continue
    fi

    log "[$processed/$total] Cloning $SOURCE_ORG/$name into mirror-clones/..."
    if dry_run_skip "clone $SOURCE_ORG/$name -> $CLONES_DIR/$name.git"; then
      success_count=$((success_count + 1)); continue
    fi

    if ! _clone_source_bare "$name"; then
      warn "Failed to clone $SOURCE_ORG/$name (empty repo or unreachable), skipping"
      failed_count=$((failed_count + 1)); continue
    fi

    # Append this repo's metadata to the manifest.
    local mtmp
    mtmp="$(mktemp)"
    jq --arg n "$name" --arg p "$private" --arg d "$default_branch" \
      '.repos += [{name:$n, private:($p=="true"), default_branch:$d}]' \
      "$manifest_tmp" > "$mtmp" && mv "$mtmp" "$manifest_tmp"

    ok "Cloned $name"
    success_count=$((success_count + 1))
    pause 0.3
  done < <(echo "$repos" | jq -c '.[]')

  if [[ "$DRY_RUN" -eq 0 ]]; then
    mv "$manifest_tmp" "$MANIFEST_FILE"
    log "Wrote manifest: $MANIFEST_FILE ($success_count repos)"
    commit_state "mirror: export stage 02 repo manifest ($success_count repos) [skip ci]"
  else
    rm -f "$manifest_tmp"
  fi

  log "Stage 02 (export) complete — cloned=$success_count failed=$failed_count total=$total"
}

# ---------------------------------------------------------------------------
# Mode: import — create target repos + push local clones (no source access)
# ---------------------------------------------------------------------------
_run_import() {
  if [[ ! -f "$MANIFEST_FILE" ]]; then
    err "Manifest not found: $MANIFEST_FILE — run MIRROR_MODE=export first"
    exit 1
  fi

  local total
  total="$(jq -r '.repos | length' "$MANIFEST_FILE" 2>/dev/null || echo 0)"
  log "Importing $total repos from manifest $MANIFEST_FILE"

  local processed=0 success_count=0 failed_count=0

  while IFS= read -r entry; do
    local name private
    name="$(echo "$entry" | jq -r '.name')"
    private="$(echo "$entry" | jq -r 'if .private then "true" else "false" end')"

    processed=$((processed + 1))
    (( processed % 10 == 0 )) && log "Progress: $processed/$total repos processed..."

    log "[$processed/$total] Importing $name -> $TARGET_ORG/$name..."
    if dry_run_skip "create+push $TARGET_ORG/$name (private=$private)"; then
      success_count=$((success_count + 1)); continue
    fi

    if ! _create_target_repo_if_absent "$name" "$private"; then
      warn "Failed to create $TARGET_ORG/$name, skipping"
      failed_count=$((failed_count + 1)); continue
    fi

    if _push_clone_to_target "$name"; then
      ok "Imported $name"
      success_count=$((success_count + 1))
    else
      failed_count=$((failed_count + 1))
    fi
    pause 0.5
  done < <(jq -c '.repos[]?' "$MANIFEST_FILE")

  log "Stage 02 (import) complete — success=$success_count failed=$failed_count total=$total"
}

# ---------------------------------------------------------------------------
main() {
  check_dry_run "$@"
  preflight

  log "Stage 02 — mirror-repos starting (mode=$MIRROR_MODE)"
  mkdir -p "$CLONES_DIR"

  case "$MIRROR_MODE" in
    full)   _run_full ;;
    export) _run_export ;;
    import) _run_import ;;
  esac
}

main "$@"
