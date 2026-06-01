# Export / Import mode — implementation status

**COMPLETE.** The `MIRROR_MODE` feature (full / export / import) is implemented
across `lib/common.sh`, all 14 stage scripts, `.gitignore`, and the Mirror
workflow. User-facing documentation lives in **`mirror/README.md` → "Run modes
(`MIRROR_MODE`)"**. This file is just an implementation record.

## What was built

- **`lib/common.sh`**: `MIRROR_MODE` global + validation; predicates `in_full`,
  `in_export`, `in_import`, `reads_source`, `writes_target`; `gh()` wrapper that
  hard-fails on target access in export mode; `ghsrc()` wrapper that hard-fails
  on source access in import mode; mode-aware `preflight` (each mode requires
  only the creds for the org it contacts); `state_items` helper.
- **`.gitignore`**: `mirror-clones/` (gitignored store for binary blobs).
- **Stage 02** (repos): export = bare clone → `mirror-clones/<repo>.git` +
  `state/repos-manifest.json`; import = create target repos + push clones.
- **Stage 05** (issues) & **06** (PRs): export serializes raw source objects +
  comments into state; import rebuilds attribution/markers and creates in target.
  Body builders verified byte-for-byte identical to full mode. Resumable via
  local state (no target read-back for dedup).
- **Stages 01 / 03 / 04 / 10 / 11 / 12 / 13 / 14**: export serializes a source
  snapshot into state (stage 11 also downloads release-asset blobs to
  `mirror-clones/release-assets/`); import replays the snapshot to the target.
- **Stages 07 (cross-refs) & 08 (assign)**: target-side post-processing —
  **no-op in export**, run normally in import/full.
- **`.github/workflows/mirror.yml`**: added a `mode` choice input and
  `MIRROR_MODE` env wiring (defaults to `full`).
- **`validate.yml`**: intentionally unchanged — validation is a source-vs-target
  comparison that needs both orgs and is not part of the export/import data flow.

## Design decisions (as agreed)

- Storage reuses the committed `state/` files; binary data (git repos, release
  assets) lives under gitignored `mirror-clones/`.
- Export stores RAW source objects; attribution headers, `@`-encoding and
  `cf-mirror` markers are built at import time (one source of truth).
- Import does NOT read the target for idempotency; it skips items already
  carrying a target number in local state (resumable, no duplicates).
- Token hygiene enforced per mode in `preflight` + the `gh`/`ghsrc` wrappers.

## Verified

- `bash -n` passes for `common.sh` and all 14 stages.
- Predicates correct for full/export/import; unknown mode fatals.
- export-mode preflight requires only source creds; import-mode requires only
  target creds.
- Stage 07 no-ops cleanly in export mode.
- Issue and PR body builders match full-mode output byte-for-byte.
- Export serialization round-trips (jq merge → import extraction) preserving
  body, labels, milestone, assignees, comments.

## Not yet done (recommended before production use)

- End-to-end runtime test against real orgs (export on one machine, copy
  `state/` + `mirror-clones/`, import on another). The logic is verified
  statically and with unit-level jq tests, but no full live round-trip has run.
- Spot-check real-PR-vs-issue-fallback parity (stage 06 import) against a repo
  with fork PRs and deleted head branches.

## Environment gotcha observed while building

This sandbox's non-interactive `echo` interprets backslashes, so
`echo "$json" | jq` on bodies containing `\n` throws "control characters must be
escaped" in throwaway test snippets — a TEST artifact only. Production runs under
real bash like the rest of the codebase. Use `printf '%s'` in test snippets.
