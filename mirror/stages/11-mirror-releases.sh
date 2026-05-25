#!/usr/bin/env bash
# mirror/stages/11-mirror-releases.sh
# Mirror GitHub Releases from source org to target org:
#   - Creates each release in target (tag, title, body, draft/prerelease flags)
#   - Prepends attribution block to release body (original author, source URL,
#     original dates) — GitHub API does not allow setting the release author
#     or published_at timestamp, so attribution is text-only.
#   - Downloads each release asset from source (via API with GH_TOKEN_SOURCE)
#     and uploads it to the target release.
#
# Idempotency:
#   - State file tracks status per tag; "mirrored" entries are skipped.
#   - Release existence in target (matched by tag_name) also skips body
#     re-creation but still attempts any missing asset uploads.
#   - Asset upload skips assets whose name already exists on the target release.
#
# Depends on: stage 02 (git tags must exist in target before release creation).
#
# State file: state/releases/<repo-name>.yaml
#
# Usage:
#   SOURCE_ORG=cyberfabric TARGET_ORG=constructorfabric \
#   GH_TOKEN=xxx GH_TOKEN_SOURCE=xxx \
#   ./mirror/stages/11-mirror-releases.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

TARGET_ORG="${TARGET_ORG:-constructorfabric}"
STATE_DIR="$REPO_ROOT/state/releases"

# ---------------------------------------------------------------------------
main() {
  check_dry_run "$@"
  preflight

  log "Stage 11 — mirror-releases starting"
  mkdir -p "$STATE_DIR"

  log "Fetching source repos from $SOURCE_ORG..."
  local repos
  repos="$(gh_paginate ghsrc "orgs/$SOURCE_ORG/repos")"
  local total_repos
  total_repos="$(echo "$repos" | jq 'length')"
  log "Found $total_repos repos in $SOURCE_ORG"

  # ---- Load excluded repos from config ------------------------------------
  local excluded_repos
  excluded_repos="$(jq -r '.stage_11_mirror_releases.exclude_repos[] // empty' \
    "$MIRROR_CONFIG" 2>/dev/null || true)"
  if [[ -n "$excluded_repos" ]]; then
    log "Excluded repos: $(echo "$excluded_repos" | tr '\n' ' ')"
  fi

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
    _mirror_repo_releases "$repo_name"
    pause 0.5

  done < <(echo "$repos" | jq -c '.[]')

  log "Stage 11 complete"

  if [[ "$DRY_RUN" -eq 0 ]]; then
    commit_state "mirror: state after stage 11 (mirror-releases) [skip ci]"
  fi
}

# ---------------------------------------------------------------------------
_mirror_repo_releases() {
  local repo_name="$1"
  local state_file="$STATE_DIR/$repo_name.yaml"

  state_init "$state_file" "11-mirror-releases"

  # Fetch all source releases (newest-first pagination)
  local releases
  releases="$(ghsrc api \
    "repos/$SOURCE_ORG/$repo_name/releases?per_page=100" \
    --paginate 2>/dev/null | jq -s 'add // []' || echo '[]')"

  local total
  total="$(echo "$releases" | jq 'length')"

  if [[ "$total" -eq 0 ]]; then
    log "  No releases in $repo_name"
    return 0
  fi

  log "  Found $total releases in $repo_name"

  # Pre-fetch existing target releases for idempotency (match by tag_name)
  local tgt_releases
  tgt_releases="$(gh api \
    "repos/$TARGET_ORG/$repo_name/releases?per_page=100" \
    --paginate 2>/dev/null | jq -s 'add // []' || echo '[]')"

  local new_count=0 skip_count=0 failed_count=0

  while IFS= read -r release; do
    local rel_id rel_tag rel_name rel_body rel_draft rel_pre
    local rel_author rel_url rel_created rel_published
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

    # ---- Idempotency via state -------------------------------------------
    local already_status
    already_status="$(jq -r --arg tag "$rel_tag" \
      '.items[] | select(.tag == $tag) | .status // empty' \
      "$state_file" 2>/dev/null | head -1 || true)"

    if [[ "$already_status" == "mirrored" ]]; then
      skip_count=$((skip_count + 1))
      continue
    fi

    # ---- Idempotency via existing target release -------------------------
    local existing_tgt_id
    existing_tgt_id="$(echo "$tgt_releases" | jq -r --arg tag "$rel_tag" \
      '.[] | select(.tag_name == $tag) | .id' 2>/dev/null | head -1 || true)"

    if [[ -n "$existing_tgt_id" ]]; then
      log "  Release '$rel_tag' already exists in target (id=$existing_tgt_id) — syncing assets"
      _upsert_release "$state_file" "$rel_id" "$rel_tag" "$rel_name" "$existing_tgt_id" "mirrored"
      _mirror_release_assets "$repo_name" "$release" "$existing_tgt_id"
      skip_count=$((skip_count + 1))
      continue
    fi

    if dry_run_skip "create release '$rel_tag' in $TARGET_ORG/$repo_name"; then
      _upsert_release "$state_file" "$rel_id" "$rel_tag" "$rel_name" "" "mirrored"
      new_count=$((new_count + 1))
      continue
    fi

    # ---- Build body with attribution preamble ---------------------------
    local attr_block
    attr_block="> **Mirrored release** | Original: ${rel_url}
> **Author:** @${rel_author} | **Created:** ${rel_created} | **Published:** ${rel_published}
> *GitHub API does not allow setting release author or timestamps — attribution preserved here.*"

    local full_body
    if [[ -n "$rel_body" ]]; then
      full_body="${attr_block}

---

${rel_body}"
    else
      full_body="$attr_block"
    fi

    # ---- Create release in target ---------------------------------------
    local payload
    payload="$(jq -n \
      --arg     tag_name    "$rel_tag" \
      --arg     name        "$rel_name" \
      --arg     body        "$full_body" \
      --argjson draft       "$rel_draft" \
      --argjson prerelease  "$rel_pre" \
      '{
        "tag_name":   $tag_name,
        "name":       $name,
        "body":       $body,
        "draft":      $draft,
        "prerelease": $prerelease
      }')"

    local create_result
    create_result="$(gh api "repos/$TARGET_ORG/$repo_name/releases" \
      --method POST \
      --input <(echo "$payload") \
      2>/dev/null || echo 'FAILED')"

    if [[ "$create_result" == "FAILED" ]]; then
      warn "  Failed to create release '$rel_tag' in $TARGET_ORG/$repo_name"
      _upsert_release "$state_file" "$rel_id" "$rel_tag" "$rel_name" "" "failed"
      failed_count=$((failed_count + 1))
      pause 0.3
      continue
    fi

    local tgt_rel_id
    tgt_rel_id="$(echo "$create_result" | jq -rs '.[0].id // empty' 2>/dev/null || true)"

    ok "  Created release '$rel_tag' (target id=$tgt_rel_id) in $TARGET_ORG/$repo_name"
    _upsert_release "$state_file" "$rel_id" "$rel_tag" "$rel_name" "$tgt_rel_id" "mirrored"

    _mirror_release_assets "$repo_name" "$release" "$tgt_rel_id"

    new_count=$((new_count + 1))
    pause 0.3

  done < <(echo "$releases" | jq -c '.[]' 2>/dev/null || true)

  state_update_stats "$state_file"
  ok "  Done $repo_name releases: new=$new_count skipped=$skip_count failed=$failed_count"
}

# ---------------------------------------------------------------------------
# _mirror_release_assets
# Downloads each asset from the SOURCE org (via GitHub API + GH_TOKEN_SOURCE,
# which handles private repo auth and redirects) and uploads it to the target
# release using `gh release upload` (uses GH_TOKEN implicitly).
#
# Idempotency: skips assets whose name already exists on the target release.
# ---------------------------------------------------------------------------
_mirror_release_assets() {
  local repo_name="$1"
  local src_release_json="$2"
  local tgt_release_id="$3"

  local rel_tag
  rel_tag="$(echo "$src_release_json" | jq -r '.tag_name')"

  local assets
  assets="$(echo "$src_release_json" | jq -c '.assets // []')"
  local asset_count
  asset_count="$(echo "$assets" | jq 'length')"

  if [[ "$asset_count" -eq 0 ]]; then
    return 0
  fi

  log "  Processing $asset_count assets for release '$rel_tag'..."

  # Fetch existing target release assets (names) for skip-check
  local tgt_asset_names
  tgt_asset_names="$(gh api \
    "repos/$TARGET_ORG/$repo_name/releases/$tgt_release_id/assets" \
    2>/dev/null | jq -rs '.[0] // [] | [.[].name]' 2>/dev/null || echo '[]')"

  local tmp_dir
  tmp_dir="$(mktemp -d)"

  while IFS= read -r asset; do
    local asset_id asset_name asset_url asset_content_type asset_size
    asset_id="$(echo           "$asset" | jq -r '.id')"
    asset_name="$(echo         "$asset" | jq -r '.name')"
    asset_url="$(echo          "$asset" | jq -r '.url')"  # API URL (not browser_download_url)
    asset_content_type="$(echo "$asset" | jq -r '.content_type // "application/octet-stream"')"
    asset_size="$(echo         "$asset" | jq -r '.size // 0')"

    # Skip if already uploaded
    local already_exists
    already_exists="$(echo "$tgt_asset_names" | jq -r --arg n "$asset_name" \
      '.[] | select(. == $n)' 2>/dev/null || true)"
    if [[ -n "$already_exists" ]]; then
      log "  Asset '$asset_name' already uploaded, skipping"
      continue
    fi

    if dry_run_skip "upload asset '$asset_name' ($(( asset_size / 1024 ))KB) for $TARGET_ORG/$repo_name release '$rel_tag'"; then
      continue
    fi

    # Download asset via API URL with source token.
    # The API URL requires Accept: application/octet-stream which redirects to
    # the actual CDN download.  browser_download_url also works but only with
    # session auth for private repos; the API URL is more reliable.
    local tmp_file="$tmp_dir/$asset_name"
    log "  Downloading '$asset_name' ($(( asset_size / 1024 ))KB)..."

    if ! curl -sL \
        -H "Authorization: Bearer $GH_TOKEN_SOURCE" \
        -H "Accept: application/octet-stream" \
        -o "$tmp_file" \
        "$asset_url" 2>/dev/null; then
      warn "  Failed to download asset '$asset_name' from $SOURCE_ORG/$repo_name release '$rel_tag'"
      rm -f "$tmp_file"
      continue
    fi

    # Verify download size sanity (non-empty file)
    if [[ ! -s "$tmp_file" ]]; then
      warn "  Downloaded asset '$asset_name' is empty — skipping upload"
      rm -f "$tmp_file"
      continue
    fi

    # Upload to target release using gh release upload.
    # --clobber: overwrite if name exists (defensive; we checked above).
    log "  Uploading '$asset_name' to target release '$rel_tag'..."
    if gh release upload "$rel_tag" "$tmp_file" \
        --repo "$TARGET_ORG/$repo_name" \
        --clobber \
        2>/dev/null; then
      ok "  Uploaded '$asset_name' to $TARGET_ORG/$repo_name release '$rel_tag'"
    else
      warn "  Failed to upload '$asset_name' to $TARGET_ORG/$repo_name release '$rel_tag'"
    fi

    rm -f "$tmp_file"
    pause 0.5

  done < <(echo "$assets" | jq -c '.[]' 2>/dev/null || true)

  rm -rf "$tmp_dir"
}

# ---------------------------------------------------------------------------
_upsert_release() {
  local state_file="$1"
  local src_id="$2"
  local tag="$3"
  local name="$4"
  local tgt_id="${5:-}"
  local status="$6"
  local ts
  ts="$(now)"

  local record
  record="$(jq -n \
    --argjson src_id "${src_id:-null}" \
    --arg     tag    "$tag" \
    --arg     name   "$name" \
    --argjson tgt_id "${tgt_id:-null}" \
    --arg     status "$status" \
    --arg     ts     "$ts" \
    '{
      source_id:   $src_id,
      tag:         $tag,
      name:        $name,
      target_id:   $tgt_id,
      status:      $status,
      mirrored_at: $ts
    }')"

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
