# Migration Guide: cyberfabric → constructorfabric

> **Executor:** Any person with org owner access to both organizations.
> **Estimated wall time:** 4–8 hours active work, spread over 1–3 days while the continuous-sync workflow keeps the target up to date.
> **Plan requirement:** Free plan — no GitHub Enterprise required.

All migration logic lives in a separate "control repo" — **`constructorfabric/cf-migration-sync`** — as numbered shell scripts plus a continuous-sync GitHub Actions workflow. This guide tells you what to run and when.

---

## What gets migrated

| Object | Method | Fidelity |
|---|---|---|
| Git history, branches, tags | `git push --mirror` | 100% — exact byte-for-byte copy |
| Releases | API copy | Full |
| Labels, milestones | API copy | Full |
| Issues + comments | API copy with author attribution in body | Content full; new author = token owner |
| Open pull requests | API recreate from mirrored branches | Same attribution caveat |
| **Closed/merged PRs** | git history only | Code preserved; PR objects NOT re-created (volume > 2 000) |
| Team memberships | API | Full (members must accept invitations) |
| Outside collaborators | API | Full |
| Secrets (names) | API listing | Names only — values must be re-entered manually |
| Actions variables (values) | API copy | Full |
| GitHub Projects v2 | Manual | No API available on free plan |
| Installed apps | Manual | Must reinstall from Marketplace |
| 2FA enforcement | Manual UI toggle | — |

---

## PHASE 0 — One-time setup

### 0.1 Create a migration token

The same person owns both `cyberfabric` and `constructorfabric`, so **one** classic personal access token works for both.

1. Go to https://github.com/settings/tokens/new (classic token, **not** fine-grained)
2. Name: `cf-migration`
3. Scopes: `repo` (full), `admin:org`, `read:user`, `workflow`
4. Expiration: 30 days
5. Save it securely — you'll paste it as `GH_TOKEN` and into the sync repo's secret

### 0.2 Install required tools

```bash
brew install gh git jq        # macOS
```

### 0.3 Create the control repo (`cf-migration-sync`)

This repo holds the scripts and the continuous-sync workflow.

```bash
export GH_TOKEN="ghp_YOUR_TOKEN"

# Create empty private repo in target org
gh repo create constructorfabric/cf-migration-sync \
  --private \
  --description "Migration tooling for cyberfabric → constructorfabric"

# Clone the bundled content (provided alongside this guide) and push it
cd ~/
git clone https://github.com/constructorfabric/cf-migration-sync.git
cd cf-migration-sync

# Copy the contents from the migration package (sync-repo-content/) into here:
cp -r /path/to/sync-repo-content/. .
git add .
git commit -m "chore: initialize migration tooling"
git branch -M main
git push -u origin main
```

> If you received this guide as part of a folder containing `sync-repo-content/`, that's the directory to copy.

### 0.4 Add the migration token as a secret

```bash
gh secret set MIGRATION_TOKEN \
  --repo constructorfabric/cf-migration-sync \
  --body "$GH_TOKEN"
```

### 0.5 Verify prerequisites

```bash
cd ~/cf-migration-sync
./scripts/00-check-prereqs.sh
```

Expected output: all checks pass; 33 repos found in cyberfabric.

---

## PHASE 1 — Initial migration

Run the scripts below in the order listed. **Each script is idempotent** — safe to re-run if interrupted.

> ⚠️ **Critical ordering note** — `08a-invite-members.sh` runs FIRST because:
> - GitHub silently drops assignees on POSTed issues/PRs if those users aren't yet org members
> - Inviting first lets people accept while the rest of Phase 1 runs (mirror, labels, etc.)
> - The longest step (`05-migrate-issues.sh`) is intentionally LAST so most people have accepted by then
> - Anyone still pending gets handled by `12-reassign.sh` (Phase 4)

> **Tip:** Run the long-running scripts (especially `05-migrate-issues.sh`) inside `tmux` or `screen` so a closed terminal doesn't kill the migration.

```bash
cd ~/cf-migration-sync
export GH_TOKEN="ghp_YOUR_TOKEN"

# ── Step 1: send invitations IMMEDIATELY so people can start accepting ──
./scripts/08a-invite-members.sh            # 1–2 min

# ── Step 2: things that don't depend on people ──
./scripts/01-mirror-all-repos.sh           # 10–30 min — 33 repos, full git history
./scripts/02-copy-repo-settings.sh         # <1 min   — topics
./scripts/03-copy-labels.sh                # 1–2 min  — required BEFORE issues
./scripts/04-copy-milestones.sh            # <1 min   — required BEFORE issues
./scripts/07-migrate-releases.sh           # <1 min
./scripts/10-apply-org-settings.sh         # <1 min
./scripts/11-secrets-and-variables.sh      # <1 min   — lists secret names; you re-enter manually

# ── Step 3: teams (pending-membership is fine; users get auto-added on accept) ──
./scripts/09-create-teams.sh               # 5 min

# ── Step 4: outside-collaborator discovery (manual follow-up below) ──
./scripts/08b-check-collaborators.sh

# ── Step 5: now migrate issues + PRs. By this point many invitees have accepted,
#    so most assignees will stick. Anyone still pending is fixed by 12-reassign.sh. ──
./scripts/05-migrate-issues.sh             # 1–2 hours — RUN IN TMUX
./scripts/06-migrate-prs.sh                # 5–10 min  — open PRs only
```

### Manual follow-ups after Phase 1

Based on the output of `08b-check-collaborators.sh`, grant each outside collaborator the same repo access in the target. Example:

```bash
gh api repos/constructorfabric/<REPO>/collaborators/<COLLAB> -X PUT -f permission='push'
```

Based on `11-secrets-and-variables.sh` output, recreate org secrets manually:
https://github.com/organizations/constructorfabric/settings/secrets/actions

---

## PHASE 2 — Enable continuous sync

After Phase 1, the workflow at `.github/workflows/continuous-sync.yml` will run every 6 hours to catch new commits, issues, and PRs created in `cyberfabric` while you finish manual steps and prepare for cutover.

### 2.1 Set the watermark to "now"

The initial migration handled everything up to this point, so the workflow should only pick up changes from here forward:

```bash
cd ~/cf-migration-sync
date -u '+%Y-%m-%dT%H:%M:%SZ' > last_sync_at.txt
git add last_sync_at.txt
git commit -m "chore: initialize watermark for continuous sync"
git push
```

### 2.2 Trigger the first run manually

```bash
gh workflow run continuous-sync.yml --repo constructorfabric/cf-migration-sync
gh run watch --repo constructorfabric/cf-migration-sync
```

Verify both jobs (`Mirror git refs` and `Sync issues & PRs`) pass. After this, the 6-hour cron schedule is active until you disable it at cutover.

---

## PHASE 3 — Manual steps (no scripts available)

These cannot be automated via the GitHub API on the free plan.

### 3.1 Install GitHub Apps (13 apps)

Visit each app's install page and authorize for `constructorfabric`:

| App | URL |
|---|---|
| qodo-code-review | https://github.com/apps/qodo-code-review/installations/new |
| graphite-app | https://github.com/apps/graphite-app/installations/new |
| coderabbitai | https://github.com/apps/coderabbitai/installations/new |
| aikido-security | https://github.com/apps/aikido-security/installations/new |
| aikido-pr-checks | https://github.com/apps/aikido-pr-checks/installations/new |
| aikido-autofix | https://github.com/apps/aikido-autofix/installations/new |
| claude | https://github.com/apps/claude/installations/new |
| dco-2 | https://github.com/apps/dco-2/installations/new |
| sonarqubecloud | https://github.com/apps/sonarqubecloud/installations/new |
| augmentcode | https://github.com/apps/augmentcode/installations/new |
| codecov | https://github.com/apps/codecov/installations/new |
| codacy-production | https://github.com/apps/codacy-production/installations/new |
| claude-design-import | https://github.com/apps/claude-design-import/installations/new |

For each: select `constructorfabric` and grant access to **all repositories**. Cross-check against cyberfabric's current configuration at https://github.com/organizations/cyberfabric/settings/installations if any app needs a narrower scope.

### 3.2 Recreate GitHub Projects v2 (11 open projects)

| Title | Source URL |
|---|---|
| Mini-Chat | https://github.com/orgs/cyberfabric/projects/15 |
| Automation and Documentation | https://github.com/orgs/cyberfabric/projects/14 |
| Insights | https://github.com/orgs/cyberfabric/projects/12 |
| CYBER WARE BACK | https://github.com/orgs/cyberfabric/projects/9 |
| PULL REQUESTS | https://github.com/orgs/cyberfabric/projects/7 |
| PROCESSES ROADMAP | https://github.com/orgs/cyberfabric/projects/5 |
| FRONTEND ROADMAP | https://github.com/orgs/cyberfabric/projects/4 |
| CYBER PILOT | https://github.com/orgs/cyberfabric/projects/3 |
| BACKEND ROADMAP | https://github.com/orgs/cyberfabric/projects/2 |

(Two closed projects — #6, #1 — don't need recreation unless you specifically want them.)

For each: copy title, description, views (Board/Table/Roadmap), custom fields, and re-link issues from the target repos.

### 3.3 Enable 2FA enforcement

1. Go to https://github.com/organizations/constructorfabric/settings/auth
2. Enable **Require two-factor authentication for everyone in the constructorfabric organization**
3. Save

---

## PHASE 4 — Re-apply assignees as invitations are accepted

When `05-migrate-issues.sh` and `06-migrate-prs.sh` ran, GitHub will have silently dropped any `assignees` whose owner had not yet accepted the org invitation. This script re-reads the source assignees and re-applies them.

```bash
cd ~/cf-migration-sync
./scripts/12-reassign.sh
```

It's safe and idempotent — run it:

- 24 hours after Phase 1 (most invitations accepted by then)
- Right before cutover (Phase 6) to catch late acceptances
- Any time someone tells you "I just accepted the invite"

For each issue/PR it logs whether all expected assignees were applied; warnings show who's still pending.

---

## PHASE 5 — Validation

```bash
cd ~/cf-migration-sync
./validate.sh
```

You'll get a PASS/FAIL summary for 15 checks. Expected at this stage:

- Checks 1, 2, 3, 9, 14, 15: PASS (immediate)
- Check 4 (issues): PASS if Phase 1 completed
- Check 5 (open PRs): PASS
- Check 6 (members): grows as people accept invitations
- Check 7 (teams): grows as people accept invitations
- Check 10 (apps): PASS only after Phase 3.1
- Check 11 (settings): PASS only after Phase 3.3 (2FA)
- Check 12 (secrets): PASS only after you re-entered them manually
- Check 13 (projects): PASS only after Phase 3.2

It's normal for some checks to fail until manual phases are done. Re-run `./validate.sh` after each manual step.

---

## PHASE 6 — Cutover (final day)

When you're ready to make `constructorfabric` the primary org and stop allowing writes to `cyberfabric`:

```bash
cd ~/cf-migration-sync

# Catch any late invitation acceptances
./scripts/12-reassign.sh

# Then run the cutover
./scripts/15-cutover.sh
```

The cutover script is interactive and will:

1. Set `cyberfabric` default permission to `read` (freezing writes)
2. Trigger one final `continuous-sync` run and wait for it to complete
3. Disable the workflow schedule

After it exits, run validation one last time:

```bash
./validate.sh
```

All 15 checks should PASS.

### Optional: redirect notice on cyberfabric

Edit `cyberfabric/.github/profile/README.md` and add at the top:

```markdown
> ⚠️ This organization has moved to [@constructorfabric](https://github.com/constructorfabric).
> All active development continues there.
```

### Cleanup

Once you're satisfied, revoke the migration token at https://github.com/settings/tokens.

---

## Appendix A — Order of operations summary

```
PHASE 0  Set up token, install tools, create cf-migration-sync repo, add secret
PHASE 1  Initial migration:
         08a (invite first!)
         01 02 03 04 07 10 11 (content + settings — no human dependency)
         09 (teams — pending memberships OK)
         08b (discovery; manual follow-up)
         05 06 (issues + PRs — last, so assignees mostly stick)
         + manual: outside-collaborator access, re-enter secret values
PHASE 2  Initialize watermark, trigger first continuous-sync run
─────── (continuous sync runs every 6 hours from here) ───────
PHASE 3  Install 13 apps + recreate 11 Projects + enable 2FA (manual)
PHASE 4  ./scripts/12-reassign.sh — re-apply assignees as invitations get accepted
         (re-run anytime; especially right before cutover)
PHASE 5  ./validate.sh — first pass
─────── (work continues in cyberfabric — sync keeps target current) ───────
PHASE 6  ./scripts/12-reassign.sh (last time)
         ./scripts/15-cutover.sh — freeze source, final sync, disable workflow
         ./validate.sh — final pass; revoke token
```

---

## Appendix B — Migrating closed/merged PRs (optional)

The migration intentionally skips ~2 000+ closed/merged PRs because the code is already in git history and recreating them as PR objects would take many hours and add little value. If you need the discussion history, write a one-off script following the pattern in `scripts/06-migrate-prs.sh` but create issues with `[Archived PR]` title prefix.
