# Validation Guide: constructorfabric Migration

All validation is automated. Run from the `cf-migration-sync` repo:

```bash
cd ~/cf-migration-sync
export GH_TOKEN="ghp_YOUR_TOKEN"

./validate.sh             # all 15 checks
./validate.sh 5           # run just check #5 (e.g. to re-verify after fixing one thing)
```

The script prints PASS/FAIL per check and a final summary. Exit code 0 = all passed, non-zero = at least one failed.

---

## The 15 checks

| # | Check | What it compares | Notes |
|---|---|---|---|
| 1 | Repository count | Lists of repo names in each org | Expects exact match (33 repos) |
| 2 | Repository details | Name, visibility, default branch | Expects exact match |
| 3 | Git history | Branch + tag counts for 3 key repos | Spot check (cyberware-rust, cyber-insight, cyberware-frontx) |
| 4 | Issues count | Open + closed issue counts per repo | Should match after Phase 1.5 completes |
| 5 | Open PRs | Open PR counts per repo | Closed/merged are NOT migrated by design |
| 6 | Members & roles | Total members in each org, owner list, pending invites | Target = source once all invites accepted |
| 7 | Teams | Membership counts for each of 6 teams + repo access | insight-app-maintainers gets push on cyber-insight & cyber-insight-front |
| 8 | Outside collaborators | List of outside collaborators in each org | Expects 3: beyond-event-horizon, dingoatemytokens, mitevsyavor |
| 9 | Labels | Label set for cyberware-rust (22 custom labels) | Spot check |
| 10 | Installed apps | App slugs installed in each org | Expects 13 apps; requires manual install per Phase 3.1 |
| 11 | Org settings | 2FA, default permission, fork policy | 2FA requires manual UI toggle per Phase 3.3 |
| 12 | Secrets & variables | Secret names + variable values | 7 Actions secrets across 3 repos (see inventory); org-level not accessible via API; values must be re-entered manually |
| 13 | GitHub Projects v2 | Project titles in each org | Numbers differ (new); requires manual recreation per Phase 3.2 |
| 14 | Org profile | `.github/profile/README.md` exists in target | Auto-migrated by Phase 1 |
| 15 | Latest commit SHA | Default-branch tip SHA for 3 key repos | Drift detection |

---

## When to run validation

| Moment | Expected result |
|---|---|
| After Phase 1 (initial migration scripts) | Checks 1, 2, 3, 4, 5, 8, 9, 14, 15 should PASS. Others depend on manual work / invitation acceptance. |
| After manual Phase 3 (apps, projects, 2FA, secrets) | Checks 10, 11, 12, 13 should PASS too. |
| As members accept invitations | Check 6, 7 progress toward PASS. |
| Final cutover (Phase 5) | All 15 should PASS. |

---

## Re-running a single check

Useful when you've just fixed one thing and want to re-verify without re-running the whole suite (which takes a few minutes against large repos):

```bash
./validate.sh 10    # only re-check installed apps
./validate.sh 12    # only re-check secrets/variables
```

---

## Interpreting failures

| Check | If FAIL, likely cause |
|---|---|
| 1 | A repo failed to create — re-run `scripts/01-mirror-all-repos.sh` |
| 2 | Topic/description not copied or default branch mismatch (e.g. `cyberware-obsidian` uses `master`) |
| 3 | Branches/tags missing — re-run `scripts/01-mirror-all-repos.sh` |
| 4 | Issue migration partial — re-run `scripts/05-migrate-issues.sh <repo-name>` for the lagging repo |
| 5 | PR migration partial — re-run `scripts/06-migrate-prs.sh <repo-name>` |
| 6 | Some invitations still pending — wait, or check `gh api orgs/constructorfabric/invitations` |
| 7 | Members haven't accepted invites yet (teams can be populated only for accepted members in some cases) |
| 8 | Outside collaborator not added — see Phase 1 manual follow-up |
| 9 | Labels not copied — re-run `scripts/03-copy-labels.sh` |
| 10 | App not installed yet — see Phase 3.1 manual steps |
| 11 | 2FA not enforced or default permission wrong — see Phase 3.3 / re-run `10-apply-org-settings.sh` |
| 12 | Org secrets not re-entered manually — see Phase 1 follow-up |
| 13 | Projects not recreated yet — see Phase 3.2 |
| 14 | `.github/profile/README.md` missing — re-run `scripts/01-mirror-all-repos.sh` for `.github` |
| 15 | Commit SHA drift — continuous-sync workflow should fix on next run, or trigger manually |
