# GitHub Org Mirror

Automated GitHub organization mirroring system. Copies repos, issues, PRs,
labels, milestones, teams, releases, branch protections, and org members from
one GitHub org (source) to another (target). Runs on a schedule via GitHub
Actions, or on demand. All state is committed back to this repo as JSON files
so runs are idempotent.

---

## Deploying to a new mirror

### 1. Create the mirror repo

In your **target** GitHub organization, create a new repository (e.g.
`org-mirror`). Copy the contents of this repo's `mirror/` folder and the
`.github/` folder into it:

```
mirror/
  lib/
  stages/
  validate/
  config.json
  README.md
.github/
  workflows/
    mirror.yml
    validate.yml
```

### 2. Configure secrets and variables

In the new repo → **Settings → Secrets and variables → Actions**:

| Name | Type | Value |
|------|------|-------|
| `GH_TOKEN` | Secret | PAT with `repo`, `admin:org`, `workflow` scopes on the **target** org |
| `GH_TOKEN_SOURCE` | Secret | PAT with `repo`, `read:org` scopes on the **source** org |
| `SOURCE_ORG` | Variable | GitHub handle of the source organization |

`TARGET_ORG` is hard-coded in the scripts — update it to your target org name,
or pass it as a workflow variable.

### 3. Edit `mirror/config.json`

```json
{
  "version": "1",
  "invite_members": true,

  "stage_01_invite_people": {
    "exclude_logins": []
  },
  "stage_05_mirror_issues": {
    "exclude_repos": []
  },
  "stage_06_mirror_prs": {
    "exclude_repos": []
  }
}
```

Set `invite_members` to `false` for a read-only backup mirror (no invitation
emails are sent, no assignees are applied, team member lists are not synced —
but the full org structure is mirrored and ready to activate at any time).

Add any repo names to `exclude_repos` that you want to skip. Add GitHub logins
to `exclude_logins` to prevent specific users from being invited.

### 4. Run stages manually (local smoke test)

```bash
export SOURCE_ORG=your-source-org
export TARGET_ORG=your-target-org
export GH_TOKEN=ghp_...             # target org token
export GH_TOKEN_SOURCE=ghp_...      # source org token

# Dry run — no API writes
./mirror/stages/01-invite-people.sh --dry-run
./mirror/stages/05-mirror-issues.sh --dry-run

# Real run — start with fast/safe stages
./mirror/stages/03-org-metadata.sh
./mirror/stages/04-repo-metadata.sh
```

## Large state files (auto-split for GitHub's 100 MB limit)

GitHub rejects any file >100 MB (and warns >50 MB). A busy repo's PR state file
(with all review diffs serialized) can be hundreds of MB, so the pipeline
automatically splits oversized state files into parts that travel through git.

How it works (transparent — you normally do nothing):
- Any `state/issues/<repo>.yaml` or `state/prs/<repo>.yaml` exceeding
  `MAX_STATE_FILE_MB` (default **10 MB**) is split into
  `<repo>.yaml.part01`, `<repo>.yaml.part02`, … plus a `<repo>.yaml.parts` manifest,
  and the whole `.yaml` is removed. Parts are **size-aware bin-packed** (an item is
  never cut in half) and each part is itself valid JSON.
- Part files deliberately do **not** end in `.yaml`, so every `*.yaml` glob in the
  pipeline still sees exactly one file per repo.
- **Merge-before-read, split-before-commit**: every stage that touches these files
  (05/06 import, 07 crossrefs, 08 assign, validation) reassembles parts into the whole
  file before reading, and re-splits after writing. On the import machine, a freshly
  pulled repo that exists only as parts is reassembled automatically.
- Round-trip is lossless (verified): merge then re-split reproduces the identical item set.

Manual control — `mirror/tools/split-state-files.sh`:
```bash
# Report which state files are over the limit:
./mirror/tools/split-state-files.sh status

# Split every oversized file under state/issues and state/prs:
./mirror/tools/split-state-files.sh split

# Split one specific file:
./mirror/tools/split-state-files.sh split state/prs/cyberware-rust.yaml

# Merge parts back into whole files (e.g. to inspect locally):
./mirror/tools/split-state-files.sh merge            # all
./mirror/tools/split-state-files.sh merge state/prs/cyber-insight.yaml
```
Override the threshold with `MAX_STATE_FILE_MB=<n>` (e.g. `MAX_STATE_FILE_MB=40`).

If a *single* issue/PR item is itself larger than the limit (e.g. one PR with a
multi-MB diff), it gets its own part and a warning is logged; if that single item
exceeds 100 MB an error is logged because GitHub will reject it (rare; needs manual
handling).

## API-rate visibility (rolling 60 minutes)

To confirm the run is staying well within GitHub's limits, every `gh` invocation
is recorded and a rolling **last-60-minutes** summary is printed periodically
(every `APIRATE_REPORT_EVERY` calls, default 50) and at the end of each import stage:

```
API rate (last 60m): 412 calls — source-read 31, target-read 47, target-write 334/350 cap (reads count invocations; --paginate may be >1 HTTP each)
```

Counts are split by GitHub's *independent* rate-limit buckets:
- **source-read** — reads from the SOURCE org (`ghsrc`).
- **target-read** — reads from the TARGET org.
- **target-write** — mutating calls to the TARGET org (POST/PATCH/PUT/DELETE,
  release upload, or a GraphQL mutation). Shown against `MAX_WRITES_PER_HOUR` —
  this is the abuse-sensitive number the write-throttle enforces.

Fidelity: counts are per `gh` **invocation**. Writes are always a single HTTP
request, so **target-write is exact**. Reads may use `--paginate` (N HTTP requests
per invocation), so source/target-read are a lower bound — the line says so.

`APIRATE_REPORT_EVERY=0` disables the periodic line (the end-of-stage line still
prints). State lives in the gitignored `state/.api-rate.log`, pruned to the
60-minute window as it goes.

### AUTORATELIMIT — adaptive backoff from GitHub's rate-limit headers

The fixed delays above are conservative by design. To instead let the run go as
fast as GitHub's *actual* primary rate limit allows, set `AUTORATELIMIT` to a
fraction of the limit you don't want to exceed:

```bash
AUTORATELIMIT=0.8 ./mirror/stages/06-mirror-prs.sh   # back off at 80% of limit
```

- `AUTORATELIMIT=0` (default) — OFF; only the fixed delays + hourly cap + 403
  hard-stop apply.
- `AUTORATELIMIT=<0..1>` — every `AUTORATELIMIT_PROBE_EVERY` writes (default **1**,
  i.e. after every write) a cheap `gh api rate_limit` probe refreshes the **core
  (REST)** and **graphql** bucket usage. When any bucket's `used/limit` reaches the
  fraction, the engine **sleeps until that bucket's reset epoch**
  (+`AUTORATELIMIT_RESET_BUFFER`, default 15s) — precise, never overshoots, never
  blows the limit. If a reset epoch isn't available it falls back to a bounded
  exponential sleep (`AUTORATELIMIT_FALLBACK_BASE`^n, capped at
  `AUTORATELIMIT_FALLBACK_MAX`).

#### Secondary (content-creation / abuse) limit — locally counted

GitHub's **secondary (abuse) limit is not exposed by any header or `rate_limit`** —
it only surfaces as a 403 + Retry-After. The dominant trigger is **content-creation
rate** (issues, comments, PRs created per minute); GitHub's documented ceiling is
~80 content-creating requests/minute. Because we make those requests, we can count
them ourselves. The write-throttle records every target-write in `state/.api-rate.log`
and the same `AUTORATELIMIT` fraction governs a **content-creation gate**:

- threshold = `AUTORATELIMIT` × `CONTENT_CREATION_LIMIT_PER_MIN` (default 80) — e.g.
  `0.8 × 80 = 64`/min.
- **After every write**, the rolling 60-second content-creation rate is measured.
  While it is at/above the threshold the gate sleeps **progressively**
  (`CONTENT_GATE_STEP_SECONDS` × step, capped at `CONTENT_GATE_MAX_SLEEP`), re-checking
  each time, until the rate drops back below — letting old events age out of the
  60s window. This makes the burst self-limit to the configured ceiling without ever
  hitting the 403.
- Knobs: `CONTENT_CREATION_LIMIT_PER_MIN` (80), `CONTENT_GATE_STEP_SECONDS` (2),
  `CONTENT_GATE_MAX_SLEEP` (60). Off entirely when `AUTORATELIMIT=0`.

The live rate is shown in the API-rate line (`content-creation 64/80 per-min (limit 64)`)
and persisted to `state/.write-throttle.json` (`content_rate_per_min`,
`content_gate_step`, `content_rate_at`). This is the **proactive** counterpart to the
403/429 hard-stop + degraded-mode handler, which remains the reactive backstop.

Tip: AUTORATELIMIT and the fixed `WRITE_DELAY_SECONDS` compose — keep a modest
`WRITE_DELAY_SECONDS` (e.g. 4–6) for smooth pacing and let AUTORATELIMIT be the
safety ceiling that reacts to the real headers.

**Rate-limit visibility.** Each probe prints a line and writes `state/.rate-limit`:

```
rate-limit [gh]: core 1234/5000 (24%, reset in 30m 49s), graphql 77/5000 (1%, reset in 30m 49s)
```

This line is also embedded in `state/.progress` (so `cat state/.progress` shows
progress + API-rate + rate-limit together). The probe runs automatically when
`AUTORATELIMIT>0`. To see this dashboard **without** enabling adaptive throttling,
set `RATELIMIT_SHOW=1` — it runs the same quota-free `rate_limit` probe every
`AUTORATELIMIT_PROBE_EVERY` writes purely for display and changes no throttle behaviour:

```bash
RATELIMIT_SHOW=1 ./mirror/stages/06-mirror-prs.sh   # show rate-limit status, no adaptive throttle
```

## Progress & ETA (issue / PR import)

Importing issues and PRs can take a long time (each write is throttled to ~10s).
Because export already serialized everything, the total work is known up front, so
stages 05 and 06 print a periodic progress line during import:

```
Progress: 39% (600/1535 issues) — 428.5/min — ETA 3m 40s — repo cyber-insight
```

- **%, done/total** — across ALL repositories combined (not per-repo).
- **rate** — items/minute, measured from observed wall-clock (so it already reflects
  the write-throttle, batch pauses, and any 403 hard-stops).
- **ETA** — recomputed each line from the live rate.
- **repo** — the repository currently being processed.

The total for PR import respects `--skip-open-prs` (open PRs are excluded from the
count) and `--repo` (single-repo runs count only that repo). Tuning knobs:
`PROGRESS_EVERY` (log every N items, default 10) and `PROGRESS_MIN_INTERVAL`
(minimum seconds between lines, default 15) — these throttle only the STDERR line.

**Easiest way to watch progress:** the stage rewrites a plain-text status file
`state/.progress` on EVERY item (not throttled), so it is always current even when
the console is busy. It carries the progress/ETA line plus the latest API-rate
summary. In addition, the write-throttle engine refreshes `state/.progress`,
`state/.api-rate.summary`, and `state/.rate-limit` **after every write** (on the
`AUTORATELIMIT_PROBE_EVERY` cadence, default 1), so even during a long single-item
operation (e.g. posting 99 comments on one PR — which ticks progress only once) the
dashboard stays live and the content-creation rate keeps updating:

```bash
cat state/.progress
# or follow it live:
watch -n 5 cat state/.progress
```

Example contents:
```
Progress: 39% (600/1535 issues) — 6.0/min — ETA 3h 45m — repo cyber-insight
API rate (last 60m): 412 calls — source-read 31, target-read 47, target-write 334/350 cap
updated: 2026-06-02T09:12:10Z
```

Runtime state files (`state/.progress`, `state/.progress.json`, `state/.progress.line`,
`state/.api-rate.log`, `state/.api-rate.summary`, `state/.rate-limit`,
`state/.write-throttle.json`) are gitignored (the whole `state/` tree is).

## Write-throttle / abuse-protection policy

Every mutating GitHub API request (issue/PR/comment creation, edits, label and
assignee changes, closes, webhook/ruleset/release writes, etc.) is automatically
throttled by a central engine in `mirror/lib/common.sh`. You do not need to add
sleeps in stage code — the `gh()` wrapper intercepts all target writes.

What the engine enforces:

| Policy | Default | Env override |
|--------|---------|--------------|
| Delay after every write | 10 s | `WRITE_DELAY_SECONDS` |
| Sustained write cap | 350 / hour (sleeps until window resets) | `MAX_WRITES_PER_HOUR` |
| Pause after every N writes | 100 writes → 300 s | `BATCH_SIZE_WRITES`, `BATCH_PAUSE_SECONDS` |
| On HTTP 403 / 429 | **hard stop**: wait `Retry-After`+60 s (or 900 s) then **degraded mode** | `RATE_LIMIT_FALLBACK_PAUSE_SECONDS` |
| Degraded mode | 20 s/write, pause every 50 writes | `DEGRADED_WRITE_DELAY_SECONDS`, `DEGRADED_BATCH_SIZE_WRITES`, `DEGRADED_BATCH_PAUSE_SECONDS` |

Key properties:
- **Single writer.** The pipeline is strictly serial — never run stages concurrently
  or background a write. The engine assumes one writer and its counters are not lock-safe.
- **Subshell-safe.** Throttle state lives in `state/.write-throttle.json` (gitignored),
  not shell variables, because writes run inside `result="$(gh api ...)"` subshells.
- **Reads are not throttled** (only `--method POST|PATCH|PUT|DELETE` and `gh release upload`
  count as writes); `ghsrc` source reads are never throttled.
- **403/429 is a hard stop, not a per-item retry.** After a rate-limit signal the engine
  pauses for the full fallback window and then runs the rest of the migration in degraded
  mode — continuing to hammer the API after a 403 is what escalates to stronger abuse limits.
- Failed items are still recorded in state and retried on the next run (idempotent via the
  `<!-- cf-mirror: ... -->` markers), so a hard stop never loses data.

Tuning for a comment-heavy migration: the policy recommends 300–350 writes/hour. The default
`MAX_WRITES_PER_HOUR=350` already reflects this; lower it if you see secondary-limit warnings.

---

### 5. Schedule via GitHub Actions

Push to the mirror repo. The workflow at `.github/workflows/mirror.yml` runs
every 6 hours. To trigger on demand:

1. Go to **Actions → Mirror**
2. Click **Run workflow**
3. Enter comma-separated stage numbers (e.g. `3,4,5`) or leave blank for all
4. Choose a **mode** (full / export / import — see below)

---

## Run modes (`MIRROR_MODE`)

Every stage supports three modes, selected by the `MIRROR_MODE` env var
(default `full`) or the workflow's **mode** input:

| Mode | Reads | Writes | Tokens needed |
|------|-------|--------|---------------|
| `full` (default) | source | target | `GH_TOKEN`, `GH_TOKEN_SOURCE`, `SOURCE_ORG`, `TARGET_ORG` |
| `export` | source only | local `state/` + `mirror-clones/` | `GH_TOKEN_SOURCE`, `SOURCE_ORG` |
| `import` | local `state/` + `mirror-clones/` | target only | `GH_TOKEN`, `TARGET_ORG` |

`full` is the original one-pass behaviour and is unchanged. `export` and
`import` split the migration in two so you can snapshot the source on one
machine and replay it onto the target on another:

- **`export`** reads the source org and serializes everything into the
  committed `state/` JSON files. Stage 02 (repo contents) and stage 11
  (release assets) are binary, so they are stored on disk under the gitignored
  `mirror-clones/` folder instead of JSON. Export **never** contacts the target;
  a stray `gh` (target) call hard-fails by design.
- **`import`** reads only `state/` (and `mirror-clones/`) and writes to the
  target. It **never** contacts the source; a stray `ghsrc` call hard-fails.
  Import is resumable: items already carrying a target number in the local
  state are skipped, so re-running after an interruption never duplicates.

```bash
# Machine A — source access only:
MIRROR_MODE=export SOURCE_ORG=your-source GH_TOKEN_SOURCE=ghp_... \
  ./mirror/stages/05-mirror-issues.sh
# ... repeat for each stage; commit state/ and copy mirror-clones/ to machine B

# Machine B — target access only (after pulling state/ + copying mirror-clones/):
MIRROR_MODE=import TARGET_ORG=your-target GH_TOKEN=ghp_... \
  ./mirror/stages/05-mirror-issues.sh
```

Notes:
- Stage 07 (rewrite cross-references) and stage 08 (assign issues) are
  target-side post-processing; they are **no-ops in export mode** and run
  normally in import mode.
- `mirror-clones/` is gitignored — for a two-machine export/import you must
  copy it across yourself (it holds bare git clones and release-asset blobs).
## CONTINUOUS=true — reconcile already-mirrored items

`CONTINUOUS=true` makes a re-run pick up changes made in the source AFTER the
initial mirror, instead of skipping anything already created. It works in both
`full` and `import` modes. Behaviour by stage:

| Stage | Without CONTINUOUS (re-run) | With CONTINUOUS=true |
|-------|-----------------------------|----------------------|
| 01 invite-people | re-checks membership (always fresh) | same |
| 02 mirror-repos  | `git push --prune` (always fresh) | same |
| 03 org-metadata  | re-PATCHes settings (always fresh) | same |
| 04 repo-metadata | re-PATCHes (always fresh) | same |
| 05 mirror-issues | skips mirrored issues | **reconciles title/body/labels/milestone/type + comments** |
| 06 mirror-prs    | skips mirrored PRs | **reconciles title/body/labels/state + comments** |
| 07 crossrefs     | skips `rewritten` items | re-rewrites items whose body was cleared by 05/06 reconcile |
| 08 assign-issues | re-applies `pending` assignees (always fresh) | same |
| 09 other-objects | re-checks webhooks (always fresh) | same |
| 10 teams         | re-PATCHes (always fresh) | same |
| 11 releases      | re-attempts assets only | **+ re-syncs release name/body** |
| 12 branch-protections | re-PUTs (always fresh) | same |
| 13 actions-variables  | upserts (always fresh) | same |
| 14 outside-collab | skips `synced` | **re-applies when permission changed** |
| 16 sub-issues    | idempotent attach (always fresh) | same |
| 17 issue-fields  | re-applies values (always fresh) | same |

So the "always fresh" stages (01-04, 08-10, 12, 13, 16, 17) reconcile on every
re-run regardless of the flag; the "create-once" stages (05, 06, 11, 14) need
CONTINUOUS to re-sync. Stage 07 picks up body changes because the 05/06 reconcile
clears the crossref record for any changed body — so **run 05/06 with CONTINUOUS
before 07**.

To fix already-migrated content (e.g. add a field added later):
```bash
CONTINUOUS=true MIRROR_MODE=import TARGET_ORG=... GH_TOKEN=... \
  ./mirror/stages/05-mirror-issues.sh
```

---

## Stages

| Stage | Script | What it does |
|-------|--------|--------------|
| 01 | `01-invite-people.sh` | Invite source org members to target org |
| 02 | `02-mirror-repos.sh` | `git push --mirror` all repos |
| 03 | `03-org-metadata.sh` | Copy org settings and profile |
| 04 | `04-repo-metadata.sh` | Copy labels, milestones, and topics per repo |
| 05 | `05-mirror-issues.sh` | Mirror issues with comments (attribution header in body) |
| 06 | `06-mirror-prs.sh` | Mirror PRs — real PRs where branch exists, closed issues otherwise |
| 07 | `07-assign-issues.sh` | Apply assignees to mirrored issues (after invitations accepted) |
| 08 | `08-other-objects.sh` | Inventory objects that require manual action |
| 10 | `10-mirror-teams.sh` | Mirror team structure and repo permissions |
| 11 | `11-mirror-releases.sh` | Mirror GitHub Releases and assets |
| 12 | `12-mirror-branch-protections.sh` | Mirror branch protection rules |
| 13 | `13-mirror-actions-variables.sh` | Mirror Actions variables (not secrets) |
| 14 | `14-mirror-outside-collaborators.sh` | Mirror outside collaborator access |

---

## Configuration reference

All configuration lives in `mirror/config.json`.

| Key | Description |
|-----|-------------|
| `invite_members` | `true` = active migration (send invites, set assignees). `false` = backup mirror |
| `stage_01_invite_people.exclude_logins` | GitHub logins never invited to target |
| `stage_05_mirror_issues.exclude_repos` | Repos skipped during issue mirroring |
| `stage_06_mirror_prs.exclude_repos` | Repos skipped during PR mirroring |
| `stage_03_org_metadata.locked_settings` | Settings forced on target regardless of source value |
| `stage_10_mirror_teams.force_privacy` | Force all teams to `"secret"` or `"closed"` |

---

## State files

Every stage writes JSON state to `state/` and commits it back:

```
state/
  people.yaml               Stage 01 — member invitation status
  org-metadata.yaml         Stage 03 — org settings snapshot
  repos/<repo>.yaml         Stage 04 — labels/milestones per repo
  issues/<repo>.yaml        Stage 05 — mirrored issues
  prs/<repo>.yaml           Stage 06 — mirrored PRs
```

State files are idempotent checkpoints — re-running any stage picks up where
it left off. Deleting a state file causes that stage to re-process the repo
from scratch.

### State file envelope

```json
{
  "meta": {
    "stage": "05-mirror-issues",
    "source_org": "...",
    "target_org": "...",
    "first_run_at": "2026-01-01T00:00:00Z",
    "last_run_at":  "2026-01-01T01:00:00Z"
  },
  "items": [ ... ],
  "stats": { "total": 0, "synced": 0, "pending": 0, "failed": 0 }
}
```

---

## Token requirements

| Token | Scopes | Purpose |
|-------|--------|---------|
| `GH_TOKEN` | `repo`, `admin:org`, `workflow` | All writes to target org |
| `GH_TOKEN_SOURCE` | `repo`, `read:org` | All reads from source org |

Tokens are kept separate so the source org is never written to and the target
org is never read with elevated privileges.

---

## GitHub Projects v2 (stage 15)

Stage 15 handles organization Projects V2 (tables/boards/roadmaps), including
**draft issues** (org-level issues not tied to a repo). Projects V2 is GraphQL-only.

```bash
# Export a full snapshot from the source org (needs read:project scope):
SOURCE_ORG=cyberfabric GH_TOKEN_SOURCE=xxx MIRROR_MODE=export \
  ./mirror/stages/15-export-projects.sh
# → state/projects.yaml (auto-split if large)

# Import into the target org (needs project scope on GH_TOKEN):
TARGET_ORG=constructorfabric GH_TOKEN=xxx MIRROR_MODE=import \
  ./mirror/stages/15-export-projects.sh
# → recreates what the API allows + writes state/projects-manual-import.md
```

**Imported automatically** (GraphQL mutations): the project, supported custom
fields (text / number / date / single-select with options), and draft issues
(title + body). Idempotent — re-running skips projects already recorded as imported.

**Manual (no GitHub write API)** — written as a per-project checklist to
`state/projects-manual-import.md`: views/dashboards (layout + filters), iteration
fields, project README, re-linking repo issue/PR items (their target numbers
differ), insights, and built-in workflows. The report includes the source values
to copy for each step.

Not run on the 6-hour schedule; trigger via the workflow `stages` input (`15`)
or run locally.

## Items requiring manual action

Stage 09 catalogs other objects that cannot be mirrored via API:

- **GitHub App installations** — must be authorized by the app owner
- **Org webhooks** — secrets are unreadable via API; reconfigure them manually
- **Wikis** — clone separately with `git clone <repo>.wiki.git` if needed

See `state/other-objects.yaml` for that inventory, and `state/projects-manual-import.md`
for Projects V2 manual steps.
