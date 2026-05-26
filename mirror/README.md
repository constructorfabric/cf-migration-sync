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

### 5. Schedule via GitHub Actions

Push to the mirror repo. The workflow at `.github/workflows/mirror.yml` runs
every 6 hours. To trigger on demand:

1. Go to **Actions → Mirror**
2. Click **Run workflow**
3. Enter comma-separated stage numbers (e.g. `3,4,5`) or leave blank for all

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
