# Mirror System — Step-by-Step Test Plan

Test each stage locally first, then test via GitHub Actions.
All commands run from the repo root (`<repo-root>`).

---

## Prerequisites

### 1. Tool versions

```bash
gh --version    # need 2.x+
jq --version    # need 1.6+
git --version   # any recent version
```

### 2. Export tokens

```bash
export GH_TOKEN=ghp_<$TARGET_ORG-owner-token>
export GH_TOKEN_SOURCE=ghp_<$SOURCE_ORG-reader-token>
export SOURCE_ORG=$SOURCE_ORG
export TARGET_ORG=$TARGET_ORG
```

Verify tokens are valid:

```bash
# Target token
gh api user --jq '.login'                          # should print your $TARGET_ORG login
gh api orgs/$TARGET_ORG --jq '.login'        # should print "$TARGET_ORG"

# Source token
GH_TOKEN="$GH_TOKEN_SOURCE" gh api orgs/$SOURCE_ORG --jq '.login'  # should print "$SOURCE_ORG"
```

### 3. Permissions checklist

| Token            | Required scopes                                |
|------------------|------------------------------------------------|
| `GH_TOKEN`       | `repo`, `admin:org`, `workflow`                |
| `GH_TOKEN_SOURCE`| `repo`, `read:org`                             |

---

## Stage 01 — Invite people

### Dry run (no API writes)

```bash
./mirror/stages/01-invite-people.sh --dry-run
```

**Expected output:**
- `[dry-run] would execute: gh api orgs/$TARGET_ORG/invitations ...` lines
- No actual invitations sent
- `state/people.yaml` is NOT created/modified (dry-run skips state commit)

### Real run

```bash
./mirror/stages/01-invite-people.sh
```

**Verify:**
```bash
# State file was created
cat state/people.yaml | jq '.meta.stage, .stats'

# Count invited vs skipped
cat state/people.yaml | jq '.stats'

# Confirm excluded users (from config.json exclude_logins) were not invited
cat state/people.yaml | jq '.items[] | select(.status == "skipped")'
# Expected: only users listed in config.json exclude_logins appear here

# Check pending invitations appeared on GitHub
gh api orgs/$TARGET_ORG/invitations --jq '.[].login' | head -10
```

**Common failures:**
- `"message": "Not Found"` on invitation → token lacks `admin:org` scope
- `"message": "Unprocessable Entity"` → user already invited or already a member (safe to ignore)
- Zero members found → `GH_TOKEN_SOURCE` invalid or lacks `read:org`

---

## Stage 02 — Mirror repos (git push)

### Dry run

Stage 02 has no `--dry-run` flag (git operations are hard to fake). Run against
one small repo first:

```bash
# Test with one small repo by temporarily editing DEFAULT_REPOS or running manually
REPO=cf-docs  # small repo
SRC_TOKEN="${GH_TOKEN_SOURCE:-$GH_TOKEN}"
git clone --mirror \
  "https://x-access-token:${SRC_TOKEN}@github.com/$SOURCE_ORG/${REPO}.git" \
  /tmp/test-mirror-${REPO}.git

# Verify clone
ls /tmp/test-mirror-${REPO}.git

# Clean up
rm -rf /tmp/test-mirror-${REPO}.git
```

### Real run

```bash
./mirror/stages/02-mirror-repos.sh
```

**Verify:**
```bash
# Compare repo counts
SRC=$(GH_TOKEN="$GH_TOKEN_SOURCE" gh api "orgs/$SOURCE_ORG/repos" --paginate --jq '.[].name' | wc -l)
TGT=$(gh api "orgs/$TARGET_ORG/repos" --paginate --jq '.[].name' | wc -l)
echo "Source: $SRC    Target: $TGT"
# Should be equal

# Spot-check branches on one repo
SRC_BRANCHES=$(GH_TOKEN="$GH_TOKEN_SOURCE" gh api "repos/$SOURCE_ORG/cf-cli/branches" --paginate --jq '.[].name' | sort)
TGT_BRANCHES=$(gh api "repos/$TARGET_ORG/cf-cli/branches" --paginate --jq '.[].name' | sort)
diff <(echo "$SRC_BRANCHES") <(echo "$TGT_BRANCHES")
# Expected: no diff
```

**Common failures:**
- `refs/pull/* rejection` → fallback to explicit refspecs (handled automatically)
- `fatal: '--mirror' can't be combined with refspecs` → handled by `git config --unset remote.origin.mirror`
- Empty repo → skipped with warning (expected)

---

## Stage 03 — Org metadata

```bash
./mirror/stages/03-org-metadata.sh --dry-run
./mirror/stages/03-org-metadata.sh
```

**Verify:**
```bash
cat state/org-metadata.yaml | jq '.meta, .items[0]'

# Compare key settings
SRC_PERM=$(GH_TOKEN="$GH_TOKEN_SOURCE" gh api orgs/$SOURCE_ORG --jq '.default_repository_permission')
TGT_PERM=$(gh api orgs/$TARGET_ORG --jq '.default_repository_permission')
echo "Source: $SRC_PERM    Target: $TGT_PERM"
# Should match
```

---

## Stage 04 — Repo metadata (labels, milestones, topics)

### Dry run first

```bash
./mirror/stages/04-repo-metadata.sh --dry-run
```

### Single repo test

Before running all repos, test with one:

```bash
# Temporarily or just observe output
./mirror/stages/04-repo-metadata.sh --dry-run 2>&1 | grep "cf-docs" | head -20
```

### Real run

```bash
./mirror/stages/04-repo-metadata.sh
```

**Verify:**
```bash
# Labels on one repo
SRC_LABELS=$(GH_TOKEN="$GH_TOKEN_SOURCE" gh api "repos/$SOURCE_ORG/cf-cli/labels" --paginate --jq '.[].name' | sort)
TGT_LABELS=$(gh api "repos/$TARGET_ORG/cf-cli/labels" --paginate --jq '.[].name' | sort)
diff <(echo "$SRC_LABELS") <(echo "$TGT_LABELS")
# Expected: no diff (or only new default labels added by GitHub)

# Milestones
SRC_MS=$(GH_TOKEN="$GH_TOKEN_SOURCE" gh api "repos/$SOURCE_ORG/cyberware-rust/milestones?state=all" --paginate --jq '.[].title' | sort)
TGT_MS=$(gh api "repos/$TARGET_ORG/cyberware-rust/milestones?state=all" --paginate --jq '.[].title' | sort)
diff <(echo "$SRC_MS") <(echo "$TGT_MS")

# State file for one repo
cat state/repos/cf-cli.yaml | jq '.stats'
```

---

## Stage 05 — Mirror issues

> **Warning:** This is the slowest stage. `cyberware-rust` alone has 1080 issues.
> Run in `tmux` or `screen`.

### Critical pre-check: labels must exist in target first

Stage 04 must complete before Stage 05, otherwise issue creation will get
`Validation Failed` for unknown labels. Verify:

```bash
gh api "repos/$TARGET_ORG/cyberware-rust/labels" --paginate --jq '.[].name' | wc -l
# Should be > 0
```

### Dry run

```bash
./mirror/stages/05-mirror-issues.sh --dry-run
```

**Expected:** prints `[dry-run] would execute: create issue '...'` for each issue.
State files are not modified. No API writes.

### Single repo test (recommended before full run)

The script currently runs all repos. To test with one small repo (`cf-docs` has 1 issue):

```bash
# Quick smoke test: run and watch output for cf-docs
./mirror/stages/05-mirror-issues.sh 2>&1 | grep -A5 "cf-docs"
```

After running, verify:

```bash
# Check state file
cat state/issues/cf-docs.yaml | jq '.stats'
# Expected: {"total":1,"synced":1,"pending":0,"failed":0}

# Verify issue exists in target with marker
gh api "repos/$TARGET_ORG/cf-docs/issues" --paginate \
  --jq '.[] | select(.body | contains("cf-mirror:"))' | jq '.number, .title'

# Idempotency check: re-run and confirm no duplicates
./mirror/stages/05-mirror-issues.sh 2>&1 | grep "cf-docs"
gh api "repos/$TARGET_ORG/cf-docs/issues" --paginate --jq '. | length'
# Count should not increase
```

### Full run (inside tmux)

```bash
tmux new -s mirror-issues
./mirror/stages/05-mirror-issues.sh
```

**Verify after completion:**
```bash
# Stats per repo
for f in state/issues/*.yaml; do
  echo "$(basename $f .yaml): $(jq -r '.stats | "total=\(.total) synced=\(.synced) failed=\(.failed)"' $f)"
done

# Compare total counts to source
for repo in cyberware-rust cyber-insight cyberware-frontx; do
  src=$(GH_TOKEN="$GH_TOKEN_SOURCE" gh api "repos/$SOURCE_ORG/$repo/issues?state=all" --paginate --jq '. | length')
  tgt=$(jq -r '.stats.synced' "state/issues/$repo.yaml" 2>/dev/null || echo "N/A")
  echo "$repo: source=$src mirrored=$tgt"
done

# No issue should be doubled (check marker uniqueness)
gh api "repos/$TARGET_ORG/cyberware-rust/issues?state=all" --paginate \
  --jq '[.[] | select(.body | contains("cf-mirror:"))] | length'
# Should equal source issue count
```

---

## Stage 06 — Mirror PRs (as issues)

```bash
./mirror/stages/06-mirror-prs.sh --dry-run
./mirror/stages/06-mirror-prs.sh
```

**Verify:**
```bash
# PRs appear as closed issues with [PR #N] prefix
gh api "repos/$TARGET_ORG/cyberware-rust/issues?state=closed" --paginate \
  --jq '[.[] | select(.title | startswith("[PR #"))] | length'

# State
cat state/prs/cyberware-rust.yaml | jq '.stats'
```

---

## Stage 07 — Assign issues

> **Warning:** Assigning issues WILL send email notifications to assignees.
> Only run this after invitations are accepted (24h+ after Stage 01).

### Pre-check: confirm org members accepted

```bash
# Check who has accepted (membership=active)
gh api "orgs/$TARGET_ORG/members" --paginate --jq '.[].login' | sort > /tmp/tgt_members.txt
cat state/people.yaml | jq -r '.items[] | select(.status == "accepted") | .login' | sort > /tmp/accepted.txt
diff /tmp/tgt_members.txt /tmp/accepted.txt
# Update state file manually if needed, or re-run Stage 01 to refresh statuses
```

### Dry run

```bash
./mirror/stages/07-assign-issues.sh --dry-run
```

**Expected:** prints `[dry-run] would execute: assign [...] to ...#N` for each pending assignment.

### Real run

```bash
./mirror/stages/07-assign-issues.sh
```

**Verify:**
```bash
# Count applied
for f in state/issues/*.yaml; do
  applied=$(jq '[.items[] | select(.assignees_status == "applied")] | length' $f)
  pending=$(jq '[.items[] | select(.assignees_status == "pending")] | length' $f)
  failed=$(jq '[.items[] | select(.assignees_status == "failed")] | length' $f)
  echo "$(basename $f .yaml): applied=$applied pending=$pending failed=$failed"
done

# failed assignments = users who haven't accepted invitation yet (expected)
```

---

## Stage 08 — Other objects inventory

```bash
./mirror/stages/08-other-objects.sh
```

**Verify:**
```bash
cat state/other-objects.yaml | jq '.'
# Shows projects, webhooks, wiki repos, installed apps — all marked "manual_action_required"
```

This stage only reads and catalogs; nothing is written to the target. Review the
output and take manual action for any items listed.

---

## Validation report

```bash
chmod +x mirror/validate/run-validation.sh
./mirror/validate/run-validation.sh
```

**Verify:**
```bash
# Find the latest report
ls -lt validation-reports/*.yaml | head -3

# Read it
cat validation-reports/*.yaml | tail -1 | xargs cat | jq '.'

# All checks should have status=pass or status=warn (not fail)
cat validation-reports/*.yaml | tail -1 | xargs cat | \
  jq '.checks[] | select(.status == "fail") | .name'
# Expected: no output
```

---

## Idempotency test (re-run everything)

After one complete run, run the full workflow again and confirm nothing is duplicated:

```bash
for stage in 01 03 04 05 06 07 08; do
  echo "Re-running stage $stage..."
  ./mirror/stages/${stage}-*.sh
  echo "---"
done
```

For each stage, the output should show mostly `skipped` counts, not `created` counts.

```bash
# Issue count should be stable
BEFORE=$(gh api "repos/$TARGET_ORG/cyberware-rust/issues?state=all" \
  --paginate --jq '. | length')
./mirror/stages/05-mirror-issues.sh 2>&1 | grep "cyberware-rust"
AFTER=$(gh api "repos/$TARGET_ORG/cyberware-rust/issues?state=all" \
  --paginate --jq '. | length')
echo "Before=$BEFORE After=$AFTER"
# Must be equal
```

---

## GitHub Actions setup

### 1. Configure secrets and variables

In the `$TARGET_ORG/cf-migration-sync` repo settings:

| Setting                           | Type     | Value                                          |
|-----------------------------------|----------|------------------------------------------------|
| Settings → Secrets → `GH_TOKEN`        | Secret   | $TARGET_ORG owner PAT                    |
| Settings → Secrets → `GH_TOKEN_SOURCE` | Secret   | $SOURCE_ORG reader PAT                         |
| Settings → Variables → `SOURCE_ORG`    | Variable | `$SOURCE_ORG`                                  |

### 2. Push this repo to GitHub

```bash
cd <repo-root>
git add mirror/ state/ validation-reports/ .github/workflows/mirror.yml .github/workflows/validate.yml
git commit -m "add: mirror system with 8-stage pipeline"
git push
```

### 3. Test workflow_dispatch (manual trigger)

1. Go to: `https://github.com/$TARGET_ORG/cf-migration-sync/actions`
2. Click **Mirror — $SOURCE_ORG → $TARGET_ORG**
3. Click **Run workflow**
4. In the `stages` field enter `3` (fast, safe org-metadata stage)
5. Click **Run workflow**

**Expected:**
- Job runs, Stage 03 completes in < 2 min
- A commit appears: `mirror: state after stage 03 (org-metadata) [skip ci]`
- `state/org-metadata.yaml` is updated

### 4. Test selective stage dispatch

```
stages: 1      # invite people only
stages: 2      # git mirror only
stages: 3,4    # metadata only
stages: 5      # issues only (slow)
stages: all    # everything
```

### 5. Test cron schedule

The workflow runs at `0 */6 * * *` (every 6 hours). After the first successful
manual run, wait for the next scheduled run and confirm:

```bash
gh run list --workflow=mirror.yml --limit=5
```

All runs should show `success` status. The commit messages should show
`[skip ci]` to prevent infinite loops.

### 6. Test the validate workflow

1. Go to Actions → **Mirror Validation Report**
2. Click **Run workflow** → **Run workflow**
3. After completion, check:
   - A new file in `validation-reports/`
   - Artifacts tab shows `validation-report` artifact (downloadable)

---

## Known limitations

| Limitation | Detail |
|------------|--------|
| Stage 07 triggers notifications | GitHub REST API has no "suppress notification" option. Only run Stage 07 after team is ready to receive them. |
| Open PRs not mirrored | Stage 06 only mirrors closed/merged PRs. Open PRs are live dev work and should be recreated manually if needed. |
| GitHub Projects v2 | No free-tier API for creating projects. Stage 08 catalogs them; recreate manually. |
| Webhook secrets | Unreadable via API. Stage 08 lists webhook URLs; reconfigure secrets manually. |
| Wiki repos | Not mirrored automatically. Clone with `git clone <repo>.wiki.git` if needed. |
| Assignee notifications | Cannot be suppressed via GitHub REST API. |

---

## Rollback

If a test run creates unwanted issues, delete them with the cleanup script:

```bash
# Preview first
./scripts/00-cleanup-migrated-issues.sh cf-docs

# If needed, remove state file so next run starts fresh
rm state/issues/cf-docs.yaml
```

---

## Recommended test sequence

```
Day 1:  Stage 01 --dry-run  → verify member list
        Stage 01 real       → send invitations
        Stage 02            → git mirror all repos
        Stage 03 + 04       → copy metadata

Day 2:  Stage 05 --dry-run  → count issues to migrate
        Stage 05 real       → migrate issues (run in tmux, takes 1-2h for large repos)
        Stage 06            → mirror closed PRs
        Stage 08            → catalog manual-action items

Day 3+: Stage 07            → apply assignees (after invitations accepted)
        Validation report   → review all 10 checks
        Re-run all stages   → confirm idempotency
        Push to GitHub      → configure secrets, test via Actions
        Wait for cron run   → confirm automated 6h cadence works
```
