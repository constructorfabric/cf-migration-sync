#!/usr/bin/env bash
# mirror/stages/11-mirror-releases.sh
# Mirror GitHub Releases from source org to target org:
#   - Creates each release in target (tag, title, body, draft/prerelease flags)
#   - Prepends attribution block to release body (original author, source URL,
#     original dates) — GitHub API does not allow setting the release author
#     or published_at timestamp, so attribution is text-only.
#   - Downloads each release asset from source and uploads it to the target.
#
# Modes (MIRROR_MODE):
#   full   — fetch source releases, create in target, download+upload assets (default).
#   export — fetch source releases into state (.source_releases per repo) AND
#            download each asset to the gitignored mirror-clones/release-assets/
#            folder. NEVER contacts the target org.
#   import — read serialized releases from state, create them in target, and
#            upload assets from the local release-assets folder. NEVER contacts source.
#
# Like stage 02, release ASSETS are binary and cannot live in JSON, so export
# keeps them on disk (gitignored) and import replays them.
#
# Idempotency:
#   - State file tracks status per tag; "mirrored" entries are skipped.
#   - Release existence in target (matched by tag_name) skips body re-creation
#     but still attempts any missing asset uploads.
#   - Asset upload skips assets whose name already exists on the target release.
#
# Depends on: stage 02 (git tags must exist in target before release creation).
#
# State file: state/releases/<repo-name>.yaml
#
# Usage:
#   SOURCE_ORG=cyberfabric TARGET_ORG=constructorfabric \
#   GH_TOKEN=xxx GH_TOKEN_SOURCE=xxx \
#   MIRROR_MODE=full|export|import \
#   ./mirror/stages/11-mirror-releases.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

TARGET_ORG="${TARGET_ORG:-}"   # required; validated in preflight (no hardcoded default)
STATE_DIR="$REPO_ROOT/state/releases"
# Gitignored local store for downloaded release assets (export → import handoff).
ASSETS_DIR="$REPO_ROOT/mirror-clones/release-assets"

# ---------------------------------------------------------------------------
main() {
  check_dry_run "$@"
  preflight

  log "Stage 11 — mirror-releases starting (mode=$MIRROR_MODE)"
  mkdir -p "$STATE_DIR"

  if in_import; then
    _import_all_releases
    log "Stage 11 complete (import)"
    [[ "$DRY_RUN" -eq 0 ]] && commit_state "mirror: import stage 11 (mirror-releases) [skip ci]"
    return 0
  fi

  log "Fetching source repos from $SOURCE_ORG..."
  local repos total_repos
  repos="$(gh_paginate ghsrc "orgs/$SOURCE_ORG/repos")"
  total_repos="$(echo "$repos" | jq 'length')"
  log "Found $total_repos repos in $SOURCE_ORG"

  local excluded_repos
  excluded_repos="$(jq -r '.stage_11_mirror_releases.exclude_repos[] // empty' \
    "$MIRROR_CONFIG" 2>/dev/null || true)"
  [[ -n "$excluded_repos" ]] && log "Excluded repos: $(echo "$excluded_repos" | tr '\n' ' ')"

  local repo_idx=0
  while IFS= read -r repo; do
    local repo_name
    repo_name="$(echo "$repo" | jq -r '.name')"
    repo_idx=$((repo_idx + 1))
    if [[ -n "$excluded_repos" ]] && echo "$excluded_repos" | grep -qx "$repo_name" 2>/dev/null; then
      log "[$repo_idx/$total_repos] Skipping excluded repo: $repo_name"
      continue
    fi
    log "[$repo_idx/$total_repos] Processing releases for $repo_name..."
    if in_export; then
      _export_repo_releases "$repo_name"
    else
      _mirror_repo_releases "$repo_name"
    fi
    pause 0.5
  done < <(echo "$repos" | jq -c '.[]')

  log "Stage 11 complete"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    commit_state "mirror: state after stage 11 (mirror-releases, mode=$MIRROR_MODE) [skip ci]"
  fi
}

# ---------------------------------------------------------------------------
# _build_release_body <tag> <name> <body> <author> <url> <created> <published>
# Emits the attribution-prefixed release body. Identical to the full-mode build.
_build_release_body() {
  local rel_url="$5" rel_author="$4" rel_created="$6" rel_published="$7" rel_body="$3"
  local attr_block
  attr_block="> **Mirrored release** | Original: ${rel_url}
> **Author:** @${rel_author} | **Created:** ${rel_created} | **Published:** ${rel_published}
> *GitHub API does not allow setting release author or timestamps — attribution preserved here.*"
  if [[ -n "$rel_body" ]]; then
    printf '%s\n\n---\n\n%s' "$attr_block" "$rel_body"
  else
    printf '%s' "$attr_block"
  fi
}

# _create_target_release <repo> <release_json> <state_file> — create one release
# in the target (or reuse existing by tag) and upload its assets. TARGET writes +
# local asset reads only. Shared by full and import. <assets_mode> = download|local.
_create_target_release() {
  local repo_name="$1" release="$2" state_file="$3" assets_mode="$4"

  local rel_id rel_tag rel_name rel_body rel_draft rel_pre rel_author rel_url rel_created rel_published
  rel_id="$(echo        "$release" | jq -r '.id')"
  rel_tag="$(echo       "$release" | jq -r '.tag_name')"
  rel_name="$(echo      "$release" | jq -r '.name // ""')"
  rel_body="$(echo      "$release" | jq -r '.body // ""')"
  rel_draft="$(echo     "$release" | jq -r '.draft // false')"
  rel_pre="$(echo       "$release" | jq -r '.prerelease // false')"
  rel_author="$(echo    "$release" | jq -r '.author.login // "unknown"')"
  rel_url="$(echo       "$release" | jq -r '.html_url // ""')"
  rel_created="$(echo   "$release" | jq -r '.created_at // ""')"
  rel_published="$(echo "$release" | jq -r '.published_at // ""')"

  local already_status
  already_status="$(jq -r --arg tag "$rel_tag" \
    '.items[] | select(.tag == $tag) | .status // empty' \
    "$state_file" 2>/dev/null | head -1 || true)"
  if [[ "$already_status" == "mirrored" ]]; then
    local known_tgt_id
    known_tgt_id="$(jq -r --arg tag "$rel_tag" '.items[] | select(.tag == $tag) | .target_id // empty' "$state_file" 2>/dev/null | head -1 || true)"
    # CONTINUOUS mode: re-sync the release name + body from source (it may have been
    # edited after the initial mirror). Without CONTINUOUS we only re-attempt assets.
    if [[ "${CONTINUOUS:-false}" == "true" && -n "$known_tgt_id" && "$known_tgt_id" != "null" \
          && "$DRY_RUN" -eq 0 ]]; then
      local _full_body _ptmp
      _full_body="$(_build_release_body "$rel_tag" "$rel_name" "$rel_body" "$rel_author" "$rel_url" "$rel_created" "$rel_published")"
      _ptmp="$(mktemp)"
      printf '%s' "$_full_body" | jq -Rs --arg name "$rel_name" '{"name":$name,"body":.}' > "$_ptmp"
      gh api "repos/$TARGET_ORG/$repo_name/releases/$known_tgt_id" \
        --method PATCH --input "$_ptmp" 2>/dev/null \
        && log "  [continuous] Reconciled release '$rel_tag' name/body" \
        || warn "  [continuous] Failed to reconcile release '$rel_tag'"
      rm -f "$_ptmp"
    fi
    # Always re-attempt asset upload (idempotent) in case a prior run was interrupted.
    if [[ -n "$known_tgt_id" && "$known_tgt_id" != "null" ]]; then
      _upload_release_assets "$repo_name" "$release" "$known_tgt_id" "$assets_mode"
    fi
    return 10   # signal: skipped
  fi

  local existing_tgt_id
  existing_tgt_id="$(gh api "repos/$TARGET_ORG/$repo_name/releases?per_page=100" --paginate 2>/dev/null \
    | jq -rs --arg tag "$rel_tag" '[.[] | select(type=="array") | .[] | select(type=="object")] | map(select(.tag_name == $tag)) | .[0].id // empty' 2>/dev/null | head -1 || true)"

  if [[ -n "$existing_tgt_id" ]]; then
    log "  Release '$rel_tag' already exists in target (id=$existing_tgt_id) — syncing assets"
    _upsert_release "$state_file" "$rel_id" "$rel_tag" "$rel_name" "$existing_tgt_id" "mirrored"
    _upload_release_assets "$repo_name" "$release" "$existing_tgt_id" "$assets_mode"
    return 10
  fi

  if dry_run_skip "create release '$rel_tag' in $TARGET_ORG/$repo_name"; then
    _upsert_release "$state_file" "$rel_id" "$rel_tag" "$rel_name" "" "mirrored"
    return 0
  fi

  local full_body
  full_body="$(_build_release_body "$rel_tag" "$rel_name" "$rel_body" "$rel_author" "$rel_url" "$rel_created" "$rel_published")"

  local payload _tmp
  payload="$(printf '%s' "$full_body" | jq -Rs \
    --arg tag_name "$rel_tag" --arg name "$rel_name" \
    --argjson draft "$rel_draft" --argjson prerelease "$rel_pre" \
    '{"tag_name":$tag_name,"name":$name,"body":.,"draft":$draft,"prerelease":$prerelease}')"
  _tmp="$(mktemp)"; printf '%s' "$payload" > "$_tmp"
  local create_result
  create_result="$(gh api "repos/$TARGET_ORG/$repo_name/releases" --method POST --input "$_tmp" 2>/dev/null)" || create_result='FAILED'
  rm -f "$_tmp"

  if [[ "$create_result" == "FAILED" ]]; then
    warn "  Failed to create release '$rel_tag' in $TARGET_ORG/$repo_name"
    _upsert_release "$state_file" "$rel_id" "$rel_tag" "$rel_name" "" "failed"
    pause 0.3
    return 1
  fi

  local tgt_rel_id
  tgt_rel_id="$(echo "$create_result" | jq -rs '.[0].id // empty' 2>/dev/null || true)"
  ok "  Created release '$rel_tag' (target id=$tgt_rel_id) in $TARGET_ORG/$repo_name"
  _upsert_release "$state_file" "$rel_id" "$rel_tag" "$rel_name" "$tgt_rel_id" "mirrored"
  _upload_release_assets "$repo_name" "$release" "$tgt_rel_id" "$assets_mode"
  pause 0.3
  return 0
}

# ---------------------------------------------------------------------------
# Full mode: original one-pass behaviour (assets downloaded just-in-time).
_mirror_repo_releases() {
  local repo_name="$1"
  local state_file="$STATE_DIR/$repo_name.yaml"
  state_init "$state_file" "11-mirror-releases"

  local releases total
  releases="$(ghsrc api "repos/$SOURCE_ORG/$repo_name/releases?per_page=100" --paginate 2>/dev/null \
    | jq -rs '[.[] | select(type=="array") | .[] | select(type=="object")]')" || releases='[]'
  total="$(echo "$releases" | jq -r 'if type=="array" then length else 0 end' 2>/dev/null || echo 0)"
  [[ "$total" -eq 0 ]] && { log "  No releases in $repo_name"; return 0; }
  log "  Found $total releases in $repo_name"

  local new_count=0 skip_count=0 failed_count=0
  while IFS= read -r release; do
    local rc=0
    _create_target_release "$repo_name" "$release" "$state_file" "download" || rc=$?
    case "$rc" in
      0)  new_count=$((new_count + 1)) ;;
      10) skip_count=$((skip_count + 1)) ;;
      *)  failed_count=$((failed_count + 1)) ;;
    esac
  done < <(echo "$releases" | jq -c '.[]' 2>/dev/null || true)

  state_update_stats "$state_file"
  ok "  Done $repo_name releases: new=$new_count skipped=$skip_count failed=$failed_count"
}

# ---------------------------------------------------------------------------
# Export mode: serialize releases into state + download assets to local store.
_export_repo_releases() {
  local repo_name="$1"
  local state_file="$STATE_DIR/$repo_name.yaml"
  state_init "$state_file" "11-mirror-releases"

  local releases total
  releases="$(ghsrc api "repos/$SOURCE_ORG/$repo_name/releases?per_page=100" --paginate 2>/dev/null \
    | jq -rs '[.[] | select(type=="array") | .[] | select(type=="object")]')" || releases='[]'
  total="$(echo "$releases" | jq -r 'if type=="array" then length else 0 end' 2>/dev/null || echo 0)"
  [[ "$total" -eq 0 ]] && { log "  No releases in $repo_name"; return 0; }
  log "  [export] Found $total releases in $repo_name"

  # Store the raw releases array for import.
  # B3 FIX: clean up both _rel_tmp and _tmp (jq output) even when jq succeeds
  # (mv moves _tmp → state_file, so rm -f on the moved path is a harmless no-op)
  # or when jq fails (_tmp exists but was never moved).
  local _rel_tmp _tmp
  _rel_tmp="$(mktemp)"; printf '%s' "$releases" > "$_rel_tmp"
  _tmp="$(mktemp)"
  jq --slurpfile rel "$_rel_tmp" --arg ts "$(now)" \
    '.source_releases = $rel[0] | .exported_at = $ts' "$state_file" > "$_tmp" && mv "$_tmp" "$state_file"
  rm -f "$_rel_tmp" "$_tmp"   # _tmp is a no-op if mv succeeded (already renamed)

  # Download assets to local store.
  local downloaded=0
  while IFS= read -r release; do
    _download_release_assets "$repo_name" "$release" && downloaded=$((downloaded + 1)) || true
  done < <(echo "$releases" | jq -c '.[]' 2>/dev/null || true)

  ok "  [export] Serialized $total releases for $repo_name (assets downloaded for $downloaded)"
}

# ---------------------------------------------------------------------------
# Import mode: read serialized releases from every state file and create them.
_import_all_releases() {
  shopt -s nullglob
  local files=( "$STATE_DIR"/*.yaml )
  shopt -u nullglob
  if [[ ${#files[@]} -eq 0 ]]; then
    warn "No state files in $STATE_DIR — run MIRROR_MODE=export first"
    return 0
  fi
  local f
  for f in "${files[@]}"; do
    local repo_name releases total
    repo_name="$(basename "$f" .yaml)"
    releases="$(jq -c '.source_releases // []' "$f" 2>/dev/null || echo '[]')"
    total="$(echo "$releases" | jq 'length' 2>/dev/null || echo 0)"
    [[ "$total" -eq 0 ]] && continue
    log "Importing $total releases for $repo_name..."
    local new_count=0 skip_count=0 failed_count=0
    while IFS= read -r release; do
      local rc=0
      _create_target_release "$repo_name" "$release" "$f" "local" || rc=$?
      case "$rc" in
        0)  new_count=$((new_count + 1)) ;;
        10) skip_count=$((skip_count + 1)) ;;
        *)  failed_count=$((failed_count + 1)) ;;
      esac
    done < <(echo "$releases" | jq -c '.[]' 2>/dev/null || true)
    state_update_stats "$f"
    ok "  [import] $repo_name releases: new=$new_count skipped=$skip_count failed=$failed_count"
    pause 0.5
  done
}

# ---------------------------------------------------------------------------
# _download_release_assets <repo> <release_json> — download all assets for a
# release from SOURCE into ASSETS_DIR/<repo>/<tag>/<name>. SOURCE reads only.
_download_release_assets() {
  local repo_name="$1" release="$2"
  local rel_tag assets asset_count
  rel_tag="$(echo "$release" | jq -r '.tag_name')"
  assets="$(echo "$release" | jq -c '.assets // []')"
  asset_count="$(echo "$assets" | jq 'length')"
  [[ "$asset_count" -eq 0 ]] && return 0

  local dest_dir="$ASSETS_DIR/$repo_name/$rel_tag"
  mkdir -p "$dest_dir"
  log "  [export] Downloading $asset_count assets for release '$rel_tag'..."

  while IFS= read -r asset; do
    local asset_name asset_url asset_size
    asset_name="$(echo "$asset" | jq -r '.name')"
    asset_url="$(echo  "$asset" | jq -r '.url')"
    asset_size="$(echo "$asset" | jq -r '.size // 0')"
    local dest_file="$dest_dir/$asset_name"
    [[ -s "$dest_file" ]] && { log "  Asset '$asset_name' already downloaded"; continue; }
    if dry_run_skip "download asset '$asset_name' ($(( asset_size / 1024 ))KB)"; then continue; fi
    if ! curl -sL -H "Authorization: Bearer $GH_TOKEN_SOURCE" -H "Accept: application/octet-stream" \
        -o "$dest_file" "$asset_url" 2>/dev/null || [[ ! -s "$dest_file" ]]; then
      warn "  Failed to download asset '$asset_name' from $SOURCE_ORG/$repo_name release '$rel_tag'"
      rm -f "$dest_file"
      continue
    fi
    ok "  Downloaded '$asset_name'"
    pause 0.3
  done < <(echo "$assets" | jq -c '.[]' 2>/dev/null || true)
  return 0
}

# ---------------------------------------------------------------------------
# _upload_release_assets <repo> <release_json> <tgt_release_id> <mode>
# mode = download → fetch from source then upload (full); local → upload from
# the pre-downloaded ASSETS_DIR store (import). Idempotent: skips names already
# present on the target release.
_upload_release_assets() {
  local repo_name="$1" release="$2" tgt_release_id="$3" mode="$4"
  local rel_tag assets asset_count
  rel_tag="$(echo "$release" | jq -r '.tag_name')"
  assets="$(echo "$release" | jq -c '.assets // []')"
  asset_count="$(echo "$assets" | jq 'length')"
  [[ "$asset_count" -eq 0 ]] && return 0

  log "  Processing $asset_count assets for release '$rel_tag' (mode=$mode)..."

  local tgt_asset_names
  tgt_asset_names="$(gh api "repos/$TARGET_ORG/$repo_name/releases/$tgt_release_id/assets" \
    2>/dev/null | jq -rs '.[0] // [] | [.[].name]' 2>/dev/null)" || tgt_asset_names='[]'

  local tmp_dir=""
  [[ "$mode" == "download" ]] && tmp_dir="$(mktemp -d)"

  while IFS= read -r asset; do
    local asset_name asset_url asset_size
    asset_name="$(echo "$asset" | jq -r '.name')"
    asset_url="$(echo  "$asset" | jq -r '.url')"
    asset_size="$(echo "$asset" | jq -r '.size // 0')"

    if [[ -n "$(echo "$tgt_asset_names" | jq -r --arg n "$asset_name" '.[] | select(. == $n)' 2>/dev/null || true)" ]]; then
      log "  Asset '$asset_name' already uploaded, skipping"
      continue
    fi
    if dry_run_skip "upload asset '$asset_name' ($(( asset_size / 1024 ))KB) for release '$rel_tag'"; then continue; fi

    local upload_file
    if [[ "$mode" == "local" ]]; then
      upload_file="$ASSETS_DIR/$repo_name/$rel_tag/$asset_name"
      if [[ ! -s "$upload_file" ]]; then
        warn "  Local asset '$asset_name' missing at $upload_file — run export first; skipping"
        continue
      fi
    else
      upload_file="$tmp_dir/$asset_name"
      log "  Downloading '$asset_name' ($(( asset_size / 1024 ))KB)..."
      if ! curl -sL -H "Authorization: Bearer $GH_TOKEN_SOURCE" -H "Accept: application/octet-stream" \
          -o "$upload_file" "$asset_url" 2>/dev/null || [[ ! -s "$upload_file" ]]; then
        warn "  Failed to download asset '$asset_name' from $SOURCE_ORG/$repo_name release '$rel_tag'"
        rm -f "$upload_file"
        continue
      fi
    fi

    log "  Uploading '$asset_name' to target release '$rel_tag'..."
    if gh release upload "$rel_tag" "$upload_file" --repo "$TARGET_ORG/$repo_name" --clobber 2>/dev/null; then
      ok "  Uploaded '$asset_name' to $TARGET_ORG/$repo_name release '$rel_tag'"
    else
      warn "  Failed to upload '$asset_name' to $TARGET_ORG/$repo_name release '$rel_tag'"
    fi
    [[ "$mode" == "download" ]] && rm -f "$upload_file"
    pause 0.5
  done < <(echo "$assets" | jq -c '.[]' 2>/dev/null || true)

  [[ -n "$tmp_dir" ]] && rm -rf "$tmp_dir"
  return 0
}

# ---------------------------------------------------------------------------
_upsert_release() {
  local state_file="$1" src_id="$2" tag="$3" name="$4" tgt_id="${5:-}" status="$6"
  local ts
  ts="$(now)"
  local record
  record="$(jq -n \
    --argjson src_id "${src_id:-null}" --arg tag "$tag" --arg name "$name" \
    --argjson tgt_id "${tgt_id:-null}" --arg status "$status" --arg ts "$ts" \
    '{source_id:$src_id, tag:$tag, name:$name, target_id:$tgt_id, status:$status, mirrored_at:$ts}')"
  local tmp
  tmp="$(mktemp)"
  jq --arg tag "$tag" --argjson rec "$record" \
    'if (.items | map(select(.tag == $tag)) | length) > 0
     then .items = [.items[] | if .tag == $tag then $rec else . end]
     else .items += [$rec]
     end' \
    "$state_file" > "$tmp"
  mv "$tmp" "$state_file"
}

main "$@"
