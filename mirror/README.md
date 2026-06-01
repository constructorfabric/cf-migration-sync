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
- `CONTINUOUS=true` reconciliation applies to `full` mode.

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

## Items requiring manual action

Stage 08 catalogs objects that cannot be mirrored via API:

- **GitHub Projects v2** — no API for creating them; recreate manually
- **GitHub App installations** — must be authorized by the app owner
- **Org webhooks** — secrets are unreadable via API; reconfigure them manually
- **Wikis** — clone separately with `git clone <repo>.wiki.git` if needed

See `state/other-objects.yaml` for the full inventory.
