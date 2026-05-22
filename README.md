# cf-migration-sync

Migration tooling for moving the **cyberfabric** GitHub organization to **constructorfabric**.

This repo contains:

- `.github/workflows/continuous-sync.yml` — runs every 6 hours to keep target in sync with source until cutover
- `scripts/` — one-shot migration scripts, numbered in execution order
- `validate.sh` — 15-check verification (run after each major milestone)
- `last_sync_at.txt` — watermark file, updated by the workflow

## Prerequisites

Install the required tools:

```bash
brew install gh git jq        # macOS
```

Create one classic personal access token at https://github.com/settings/tokens/new with:

- `repo` (full)
- `admin:org`
- `read:user`
- `workflow`

The same person owns both orgs, so a single token works for both.

> **Two-token setup (recommended if source org has restrictions):**
> If your `GH_TOKEN` has limited read access to the source org, create a second token
> with broader read permissions and set `GH_TOKEN_SOURCE`. Scripts use `GH_TOKEN_SOURCE`
> for source-org reads and `GH_TOKEN` for all target-org writes.
>
> ```bash
> export GH_TOKEN="ghp_YOUR_TARGET_TOKEN"           # target + fallback source
> export GH_TOKEN_SOURCE="ghp_YOUR_SOURCE_TOKEN"    # source (if different)
> ```

Then in every terminal session:

```bash
export GH_TOKEN="ghp_YOUR_TOKEN"
```

Verify with:

```bash
./scripts/00-check-prereqs.sh
```

## Migration order

Run scripts in the sequence below. Each is idempotent — safe to re-run.

> ⚠️ **`08a-invite-members.sh` is FIRST on purpose.**
> GitHub silently drops issue/PR assignees who aren't yet org members. Inviting
> first lets people accept while the rest of Phase 1 runs. Issues are migrated
> LAST (when most people have accepted). Anyone still pending is handled by
> `12-reassign.sh`, which can be re-run anytime.

| Step | Script | What it does | Time |
|---|---|---|---|
| 0 | `scripts/00-check-prereqs.sh` | Verify token + tools | <1 min |
| 1 | `scripts/08a1-invite-tier1.sh` | **Invite Tier 1** — highest-issue users first | <1 min |
| 2 | `scripts/08a2-invite-tier2.sh` | **Invite Tier 2** — active contributors | <1 min |
| 3 | `scripts/08a3-invite-tier3.sh` | **Invite Tier 3** — remaining members | <1 min |
| 4 | `scripts/08a4-invite-tier4.sh` | **Invite Tier 4** — occasional contributors | <1 min |
| 5 | `scripts/01-mirror-all-repos.sh` | Create + mirror all 33 repos with full git history | 10–30 min |
| 6 | `scripts/02-copy-repo-settings.sh` | Copy topics | <1 min |
| 7 | `scripts/03-copy-labels.sh` | Copy labels (required before issues) | 1–2 min |
| 8 | `scripts/04-copy-milestones.sh` | Copy milestones (required before issues) | <1 min |
| 9 | `scripts/07-migrate-releases.sh` | Copy GitHub Releases | <1 min |
| 10 | `scripts/10-apply-org-settings.sh` | Default permission + fork policy | <1 min |
| 11 | `scripts/11-secrets-and-variables.sh` | List secret names + copy variables | <1 min |
| 12 | `scripts/09-create-teams.sh` | Create + populate 6 teams, assign repo access | 5 min |
| 13 | `scripts/08b-check-collaborators.sh` | List outside-collaborator access (manual follow-up) | <1 min |
| 14 | `scripts/05-migrate-issues.sh` | Migrate issues + comments | **1–2 hours** (run in tmux) |
| 15 | `scripts/06-migrate-prs.sh` | Recreate open PRs (closed/merged stay in git history) | 5–10 min |
| — | **manual** | Install 13 apps (see migration guide Phase 3) | 15 min |
| — | **manual** | Recreate 11 GitHub Projects (see migration guide Phase 3) | 30–60 min |
| — | **manual** | Enable 2FA in GitHub UI | <1 min |
| 16 | `scripts/12-reassign.sh` | Re-apply assignees that were dropped (run 24h later, then again before cutover) | 2–5 min |

Then **enable continuous sync** (see next section) and let it run until cutover.

## Continuous sync workflow

After Phase 1, the workflow at `.github/workflows/continuous-sync.yml` will run every 6 hours and:

1. Mirror any new git refs from source to target
2. Copy new/changed labels and milestones
3. Sync issues created or updated since `last_sync_at.txt`
4. Recreate any new open PRs

Activate it by:

1. Add the migration token as a secret:
   ```bash
   gh secret set MIGRATION_TOKEN --repo constructorfabric/cf-migration-sync --body "$GH_TOKEN"
   ```
2. Reset the watermark to "now" (so it only syncs *future* activity — the initial migration handled everything before):
   ```bash
   date -u '+%Y-%m-%dT%H:%M:%SZ' > last_sync_at.txt
   git add last_sync_at.txt
   git commit -m "chore: initialize watermark"
   git push
   ```
3. Trigger a first manual run:
   ```bash
   gh workflow run continuous-sync.yml --repo constructorfabric/cf-migration-sync
   gh run watch --repo constructorfabric/cf-migration-sync
   ```

After the first run succeeds, the 6-hour schedule is active.

## Validation

After each major milestone (especially after the initial migration and after cutover):

```bash
./validate.sh                # run all 15 checks
./validate.sh 5              # run just check #5
```

Exits 0 if everything matches, non-zero if any check fails.

## Cutover

When ready to make `constructorfabric` the primary org:

```bash
# Catch any last-minute invitation acceptances before freezing source
./scripts/12-reassign.sh

# Then run cutover (interactive)
./scripts/15-cutover.sh
```

The cutover script:
1. Sets `cyberfabric` to read-only (default permission = read)
2. Triggers a final continuous-sync run and waits for completion
3. Disables the continuous-sync schedule

Then run `./validate.sh` one more time and announce the cutover.

## Re-running individual scripts

All scripts are idempotent. If a phase partially completes:

- `05-migrate-issues.sh` — detects already-migrated issues via the `<!-- cf-mirror: ... -->` marker and skips them. To re-migrate a single repo: `./scripts/05-migrate-issues.sh cyberware-rust`
- `06-migrate-prs.sh` — same marker approach; takes optional repo arg
- `12-reassign.sh` — designed to be re-run; each call re-applies as many assignees as possible. Pending members get added when run again later.
- All "copy" scripts — re-run safely; existing resources are updated or skipped

## Troubleshooting

| Symptom | Fix |
|---|---|
| "Missing scope: admin:org" | Regenerate token, ensure `admin:org` is checked |
| "Cannot read constructorfabric" | Confirm you accepted the org invitation OR you're an owner |
| Issue creation fails with 422 on labels | Run `03-copy-labels.sh` first |
| PR creation skipped with "branch not found" | Re-run `01-mirror-all-repos.sh` to pick up new branches |
| Rate limit (403) | Wait an hour or check `gh api rate_limit` |
| Workflow run fails | Inspect logs at Actions tab; check `MIGRATION_TOKEN` secret is set |

## See also

- `cyberfabric-inventory.md` (in source-of-truth working dir) — full inventory of what's being migrated
- `cyberfabric-migration-guide.md` — step-by-step narrative version of this README
- `cyberfabric-validation-guide.md` — narrative version of `validate.sh`
