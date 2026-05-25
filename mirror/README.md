# Mirror — cyberfabric → constructorfabric

Automated GitHub org mirroring system. Runs every 6 hours via GitHub Actions,
or on demand. All state is committed back to this repo as JSON-in-.yaml files.

## Directory layout

```
mirror/
  lib/common.sh            Shared functions, state helpers, ghsrc(), logging
  stages/
    01-invite-people.sh    Invite source org members to target org
    02-mirror-repos.sh     git push --mirror all repos
    03-org-metadata.sh     Copy org settings/profile
    04-repo-metadata.sh    Copy labels/milestones/topics per repo
    05-mirror-issues.sh    Mirror issues (without assignees)
    06-mirror-prs.sh       Mirror closed PRs as issues with link
    07-assign-issues.sh    Apply assignees to mirrored issues
    08-other-objects.sh    Inventory manual-action items
  validate/
    run-validation.sh      10-check validation report

state/                     JSON state files, committed by CI
  people.yaml
  org-metadata.yaml
  other-objects.yaml
  issues/<repo>.yaml
  repos/<repo>.yaml
  prs/<repo>.yaml

validation-reports/        Append-only report files
  YYYY-MM-DDTHH-MM-SSZ.yaml

.github/workflows/
  mirror.yml               Cron every 6h + manual dispatch
  validate.yml             Manual dispatch only
```

## Configuration

| Name              | Type     | Where          | Value                          |
|-------------------|----------|----------------|--------------------------------|
| `SOURCE_ORG`      | Variable | Repo/Org       | `cyberfabric`                  |
| `GH_TOKEN`        | Secret   | Repo/Org       | Target org token (repo, admin:org, workflow) |
| `GH_TOKEN_SOURCE` | Secret   | Repo/Org       | Source org token (repo, read:org) |
| `TARGET_ORG`      | Hardcoded| Scripts        | `constructorfabric`            |

## Running stages manually

Each stage script can be run standalone:

```bash
export SOURCE_ORG=cyberfabric
export TARGET_ORG=constructorfabric
export GH_TOKEN=ghp_...
export GH_TOKEN_SOURCE=ghp_...

# Dry run (no writes)
./mirror/stages/01-invite-people.sh --dry-run

# Real run
./mirror/stages/02-mirror-repos.sh
```

## Running specific stages via workflow_dispatch

1. Go to Actions → Mirror — cyberfabric → constructorfabric
2. Click "Run workflow"
3. In the `stages` input enter comma-separated stage numbers, e.g. `1,5,7`
4. Leave blank or enter `all` to run everything

## State file format

Every state file is JSON (stored with a .yaml extension) with this envelope:

```json
{
  "meta": {
    "stage": "01-invite-people",
    "source_org": "cyberfabric",
    "target_org": "constructorfabric",
    "first_run_at": "2026-01-01T00:00:00Z",
    "last_run_at": "2026-01-01T01:00:00Z"
  },
  "items": [ ... ],
  "stats": { "total": 0, "synced": 0, "pending": 0, "failed": 0 }
}
```

## Excluded members (stage 01)

The following source org members are never invited:
- `dfc-Acronis`
- `alexpitsikoulis`
- `gaidar`

## Manual action required

Stage 08 inventories items that cannot be mirrored automatically:

- **GitHub Projects v2** — no free-plan API for creating them; recreate manually
- **GitHub App installations** — must be authorized by app owner
- **Org webhooks** — secrets are unreadable via API; reconfigure manually  
- **Wikis** — can be mirrored via `git clone <repo>.wiki.git` if needed

See `state/other-objects.yaml` for the full inventory.

## Validation

Run the validate workflow (manual dispatch) to generate a report in
`validation-reports/`. The report covers:

1. Members: count + missing list
2. Repos: count + missing list
3. Git refs: branch/tag counts for 5 sampled repos
4. Org settings: default_repository_permission, fork policy
5. Labels: count per repo
6. Milestones: count per repo
7. Issues: mirrored vs source count
8. PRs: mirrored vs source count
9. Assignees: issues with pending assignee application
10. Manual items: objects still needing manual action
