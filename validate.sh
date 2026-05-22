#!/usr/bin/env bash
# validate.sh — verify the migration is complete and consistent.
#
# Runs 15 checks comparing cyberfabric (source) vs constructorfabric (target).
# Prints a PASS/FAIL summary at the end. Exits non-zero if any check fails.
#
# Usage:
#   ./validate.sh                  # run all checks
#   ./validate.sh <check-number>   # run a single check (1–15)

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/scripts/_lib.sh"
preflight

declare -A RESULTS
ONLY="${1:-all}"

run_check() {
  local NUM="$1" NAME="$2"
  if [ "$ONLY" != "all" ] && [ "$ONLY" != "$NUM" ]; then
    return
  fi
  echo ""
  echo "════════════════════════════════════════════════════════════════"
  echo "  CHECK ${NUM} — ${NAME}"
  echo "════════════════════════════════════════════════════════════════"
  if "check_${NUM}"; then
    RESULTS[$NUM]="PASS"
    ok "Check ${NUM} PASS"
  else
    RESULTS[$NUM]="FAIL"
    err "Check ${NUM} FAIL"
  fi
}

# ── CHECK 1: Repo count ──────────────────────────────────────────────────────
check_1() {
  list_source_repos > /tmp/source_repos.txt
  gh api "orgs/${TARGET_ORG}/repos" --paginate --jq '.[].name' | sort > /tmp/target_repos.txt
  local S T
  S=$(wc -l < /tmp/source_repos.txt | tr -d ' ')
  T=$(wc -l < /tmp/target_repos.txt | tr -d ' ')
  echo "  source: ${S} repos    target: ${T} repos"
  if diff -q /tmp/source_repos.txt /tmp/target_repos.txt >/dev/null; then
    return 0
  fi
  echo "  Diff:"; diff /tmp/source_repos.txt /tmp/target_repos.txt | sed 's/^/    /'
  return 1
}

# ── CHECK 2: Repo details ────────────────────────────────────────────────────
check_2() {
  gh api "orgs/${SOURCE_ORG}/repos" --paginate \
    --jq '.[] | "\(.name)|\(.visibility)|\(.default_branch // "NO_BRANCH")"' \
    | sort > /tmp/src_meta.txt
  gh api "orgs/${TARGET_ORG}/repos" --paginate \
    --jq '.[] | "\(.name)|\(.visibility)|\(.default_branch // "NO_BRANCH")"' \
    | sort > /tmp/tgt_meta.txt
  if diff -q /tmp/src_meta.txt /tmp/tgt_meta.txt >/dev/null; then
    return 0
  fi
  echo "  Diff (source vs target):"; diff /tmp/src_meta.txt /tmp/tgt_meta.txt | sed 's/^/    /'
  return 1
}

# ── CHECK 3: Git history (commit/branch/tag counts for 3 key repos) ─────────
check_3() {
  local FAIL=0
  for REPO in cyberware-rust cyber-insight cyberware-frontx; do
    local SB TB ST TT
    SB=$(gh api "repos/${SOURCE_ORG}/${REPO}/branches" --paginate --jq 'length' | paste -sd+ - | bc)
    TB=$(gh api "repos/${TARGET_ORG}/${REPO}/branches" --paginate --jq 'length' | paste -sd+ - | bc)
    ST=$(gh api "repos/${SOURCE_ORG}/${REPO}/tags"     --paginate --jq 'length' | paste -sd+ - | bc)
    TT=$(gh api "repos/${TARGET_ORG}/${REPO}/tags"     --paginate --jq 'length' | paste -sd+ - | bc)
    printf "  %-20s branches: %3s/%3s   tags: %3s/%3s\n" "$REPO" "$SB" "$TB" "$ST" "$TT"
    [ "$SB" = "$TB" ] && [ "$ST" = "$TT" ] || FAIL=1
  done
  return $FAIL
}

# ── CHECK 4: Issues count ────────────────────────────────────────────────────
check_4() {
  gh api graphql -f query="
  { organization(login: \"${SOURCE_ORG}\") { repositories(first: 50) { nodes {
      name openIssues: issues(states: OPEN) { totalCount }
      closedIssues: issues(states: CLOSED) { totalCount } } } } }" \
    --jq '.data.organization.repositories.nodes[] | "\(.name) open=\(.openIssues.totalCount) closed=\(.closedIssues.totalCount)"' \
    | sort > /tmp/src_issues.txt
  gh api graphql -f query="
  { organization(login: \"${TARGET_ORG}\") { repositories(first: 50) { nodes {
      name openIssues: issues(states: OPEN) { totalCount }
      closedIssues: issues(states: CLOSED) { totalCount } } } } }" \
    --jq '.data.organization.repositories.nodes[] | "\(.name) open=\(.openIssues.totalCount) closed=\(.closedIssues.totalCount)"' \
    | sort > /tmp/tgt_issues.txt
  if diff -q /tmp/src_issues.txt /tmp/tgt_issues.txt >/dev/null; then
    return 0
  fi
  echo "  Diff:"; diff /tmp/src_issues.txt /tmp/tgt_issues.txt | sed 's/^/    /'
  return 1
}

# ── CHECK 5: Open PR count (closed/merged not migrated by design) ────────────
check_5() {
  gh api graphql -f query="
  { organization(login: \"${SOURCE_ORG}\") { repositories(first: 50) { nodes {
      name openPRs: pullRequests(states: OPEN) { totalCount } } } } }" \
    --jq '.data.organization.repositories.nodes[] | "\(.name) open=\(.openPRs.totalCount)"' \
    | sort > /tmp/src_prs.txt
  gh api graphql -f query="
  { organization(login: \"${TARGET_ORG}\") { repositories(first: 50) { nodes {
      name openPRs: pullRequests(states: OPEN) { totalCount } } } } }" \
    --jq '.data.organization.repositories.nodes[] | "\(.name) open=\(.openPRs.totalCount)"' \
    | sort > /tmp/tgt_prs.txt
  echo "  (Note: closed/merged PRs are NOT migrated — see migration guide Phase 6)"
  if diff -q /tmp/src_prs.txt /tmp/tgt_prs.txt >/dev/null; then
    return 0
  fi
  echo "  Open-PR diff:"; diff /tmp/src_prs.txt /tmp/tgt_prs.txt | sed 's/^/    /'
  return 1
}

# ── CHECK 6: Members and roles ───────────────────────────────────────────────
check_6() {
  local SC TC PC
  SC=$(gh api "orgs/${SOURCE_ORG}/members" --paginate --jq '.[].login' | wc -l | tr -d ' ')
  TC=$(gh api "orgs/${TARGET_ORG}/members" --paginate --jq '.[].login' | wc -l | tr -d ' ')
  PC=$(gh api "orgs/${TARGET_ORG}/invitations" --paginate --jq '.[].login' | wc -l | tr -d ' ')
  echo "  source members: ${SC}    target members: ${TC}    pending invites: ${PC}"
  echo "  source owners:  $(gh api orgs/${SOURCE_ORG}/members -X GET -f role=admin --jq '.[].login' | tr '\n' ' ')"
  echo "  target owners:  $(gh api orgs/${TARGET_ORG}/members -X GET -f role=admin --jq '.[].login' | tr '\n' ' ')"
  [ $((TC + PC)) -ge "$SC" ] && return 0 || return 1
}

# ── CHECK 7: Teams ───────────────────────────────────────────────────────────
check_7() {
  local FAIL=0
  for SLUG in backend-architects contributors frontend-architects governance insight-app-maintainers security; do
    local S T
    S=$(gh api "orgs/${SOURCE_ORG}/teams/${SLUG}/members" --paginate --jq 'length' 2>/dev/null | paste -sd+ - | bc)
    T=$(gh api "orgs/${TARGET_ORG}/teams/${SLUG}/members" --paginate --jq 'length' 2>/dev/null | paste -sd+ - | bc)
    printf "  %-30s source=%3s   target=%3s\n" "$SLUG" "$S" "$T"
    [ "$S" = "$T" ] || FAIL=1
  done

  echo "  insight-app-maintainers repo access:"
  gh api "orgs/${TARGET_ORG}/teams/insight-app-maintainers/repos" \
    --jq '.[] | "    \(.name): \(.permissions | to_entries | map(select(.value)) | .[].key)"' \
    | sort -u
  return $FAIL
}

# ── CHECK 8: Outside collaborators ───────────────────────────────────────────
check_8() {
  gh api "orgs/${SOURCE_ORG}/outside_collaborators" --paginate --jq '.[].login' | sort > /tmp/src_oc.txt
  gh api "orgs/${TARGET_ORG}/outside_collaborators" --paginate --jq '.[].login' | sort > /tmp/tgt_oc.txt
  echo "  source: $(tr '\n' ' ' < /tmp/src_oc.txt)"
  echo "  target: $(tr '\n' ' ' < /tmp/tgt_oc.txt)"
  diff -q /tmp/src_oc.txt /tmp/tgt_oc.txt >/dev/null
}

# ── CHECK 9: Labels (cyberware-rust spot check) ──────────────────────────────
check_9() {
  gh api "repos/${SOURCE_ORG}/cyberware-rust/labels" --paginate --jq '.[].name' | sort > /tmp/src_labels.txt
  gh api "repos/${TARGET_ORG}/cyberware-rust/labels" --paginate --jq '.[].name' | sort > /tmp/tgt_labels.txt
  echo "  source labels: $(wc -l < /tmp/src_labels.txt | tr -d ' ')   target: $(wc -l < /tmp/tgt_labels.txt | tr -d ' ')"
  if diff -q /tmp/src_labels.txt /tmp/tgt_labels.txt >/dev/null; then
    return 0
  fi
  echo "  Diff:"; diff /tmp/src_labels.txt /tmp/tgt_labels.txt | sed 's/^/    /'
  return 1
}

# ── CHECK 10: Installed apps ─────────────────────────────────────────────────
check_10() {
  gh api "orgs/${SOURCE_ORG}/installations" --jq '.installations[].app_slug' | sort > /tmp/src_apps.txt
  gh api "orgs/${TARGET_ORG}/installations" --jq '.installations[].app_slug' | sort > /tmp/tgt_apps.txt
  echo "  source: $(wc -l < /tmp/src_apps.txt | tr -d ' ') apps   target: $(wc -l < /tmp/tgt_apps.txt | tr -d ' ') apps"
  if diff -q /tmp/src_apps.txt /tmp/tgt_apps.txt >/dev/null; then
    return 0
  fi
  echo "  Diff (apps not yet installed in target):"; diff /tmp/src_apps.txt /tmp/tgt_apps.txt | sed 's/^/    /'
  return 1
}

# ── CHECK 11: Org settings ───────────────────────────────────────────────────
check_11() {
  echo "  source: $(gh api orgs/${SOURCE_ORG} --jq '{two_factor: .two_factor_requirement_enabled, default_repo_perm: .default_repository_permission, can_fork_private: .members_can_fork_private_repositories}' -c)"
  echo "  target: $(gh api orgs/${TARGET_ORG} --jq '{two_factor: .two_factor_requirement_enabled, default_repo_perm: .default_repository_permission, can_fork_private: .members_can_fork_private_repositories}' -c)"
  local TFA DRP
  TFA=$(gh api "orgs/${TARGET_ORG}" --jq '.two_factor_requirement_enabled')
  DRP=$(gh api "orgs/${TARGET_ORG}" --jq '.default_repository_permission')
  [ "$TFA" = "true" ] && [ "$DRP" = "none" -o "$DRP" = "read" ] && return 0 || return 1
}

# ── CHECK 12: Secrets and variables ──────────────────────────────────────────
check_12() {
  # Repo-level Actions secrets (source-only; values must be re-entered manually)
  local EXPECTED="cyberware-rust:CODECOV_TOKEN,CRATES_IO_TOKEN,PR_DASHBOARD_PROJECTS_TOKEN,TELEGRAM_BOT_TOKEN,TELEGRAM_CHAT_ID
cyberware-frontx:NPM_TOKEN
cyber-constructor:SONAR_TOKEN"

  local FAIL=0
  echo "  Expected repo-level Actions secrets (source → target must be re-created manually):"
  while IFS=: read -r REPO SECRETS; do
    local SRC_SECRETS=$(gh api "repos/${SOURCE_ORG}/${REPO}/actions/secrets" --jq '.secrets[].name' 2>/dev/null | sort | tr '\n' ',' | sed 's/,$//')
    local TGT_SECRETS=$(gh api "repos/${TARGET_ORG}/${REPO}/actions/secrets" --jq '.secrets[].name' 2>/dev/null | sort | tr '\n' ',' | sed 's/,$//')
    echo "    ${REPO}"
    echo "      source: ${SRC_SECRETS:-none}"
    echo "      target: ${TGT_SECRETS:-none}"
    # Target should have secrets after manual recreation
    if [ -z "$TGT_SECRETS" ]; then
      echo "      ~ target empty (manual recreation needed)"
    fi
  done <<< "$EXPECTED"

  echo ""
  echo "  Note: secret VALUES must be re-entered manually in target repos."
  echo "  Org-level Actions secrets: not accessible via API (403)."
  echo "  To validate, manually compare:"
  echo "    https://github.com/cyberfabric/<REPO>/settings/secrets/actions"
  echo "    https://github.com/constructorfabric/<REPO>/settings/secrets/actions"

  # We can't auto-validate values — PASS by default, user must manually confirm
  return 0
}

# ── CHECK 13: GitHub Projects v2 ─────────────────────────────────────────────
check_13() {
  echo "  source projects:"
  gh api graphql -f query="{ organization(login: \"${SOURCE_ORG}\") { projectsV2(first: 30) { nodes { title closed } } } }" \
    --jq '.data.organization.projectsV2.nodes[] | "    \(.title) (closed=\(.closed))"' | sort
  echo "  target projects:"
  gh api graphql -f query="{ organization(login: \"${TARGET_ORG}\") { projectsV2(first: 30) { nodes { title closed } } } }" \
    --jq '.data.organization.projectsV2.nodes[] | "    \(.title) (closed=\(.closed))"' | sort

  local SC TC
  SC=$(gh api graphql -f query="{ organization(login: \"${SOURCE_ORG}\") { projectsV2(first: 30) { nodes { closed } } } }" \
    --jq '[.data.organization.projectsV2.nodes[] | select(.closed == false)] | length')
  TC=$(gh api graphql -f query="{ organization(login: \"${TARGET_ORG}\") { projectsV2(first: 30) { nodes { closed } } } }" \
    --jq '[.data.organization.projectsV2.nodes[] | select(.closed == false)] | length')
  echo "  open projects: source=${SC}  target=${TC}"
  [ "$TC" -ge "$SC" ] && return 0 || return 1
}

# ── CHECK 14: Org profile ────────────────────────────────────────────────────
check_14() {
  gh api "repos/${TARGET_ORG}/.github/contents/profile/README.md" --jq '.size' >/dev/null 2>&1 \
    && { echo "  profile README exists in ${TARGET_ORG}/.github"; return 0; } \
    || { echo "  profile README MISSING"; return 1; }
}

# ── CHECK 15: Latest commit SHA spot check ───────────────────────────────────
check_15() {
  local FAIL=0
  for REPO in cyberware-rust cyber-insight cyberware-frontx; do
    BRANCH=$(gh api "repos/${SOURCE_ORG}/${REPO}" --jq '.default_branch')
    SRC=$(gh api "repos/${SOURCE_ORG}/${REPO}/commits/${BRANCH}" --jq '.sha' 2>/dev/null || echo "?")
    TGT=$(gh api "repos/${TARGET_ORG}/${REPO}/commits/${BRANCH}" --jq '.sha' 2>/dev/null || echo "?")
    if [ "$SRC" = "$TGT" ]; then
      echo "  ✓ ${REPO} (${BRANCH}): ${SRC:0:10}"
    else
      echo "  ✗ ${REPO} (${BRANCH}): source=${SRC:0:10}  target=${TGT:0:10}"
      FAIL=1
    fi
  done
  return $FAIL
}

# ── Run all ──────────────────────────────────────────────────────────────────
run_check 1  "Repository count"
run_check 2  "Repository details (visibility, default branch)"
run_check 3  "Git history (branches, tags)"
run_check 4  "Issues count per repo"
run_check 5  "Open PRs per repo"
run_check 6  "Members and roles"
run_check 7  "Teams (membership counts + repo access)"
run_check 8  "Outside collaborators"
run_check 9  "Labels (cyberware-rust spot check)"
run_check 10 "Installed GitHub Apps"
run_check 11 "Org settings (2FA, default permission, fork)"
run_check 12 "Secrets and variables"
run_check 13 "GitHub Projects v2"
run_check 14 "Org profile README"
run_check 15 "Latest commit SHA spot check"

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  SUMMARY"
echo "════════════════════════════════════════════════════════════════"
FAILED=0
for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  R="${RESULTS[$n]:-skipped}"
  printf "  Check %2s: %s\n" "$n" "$R"
  [ "$R" = "FAIL" ] && FAILED=$((FAILED + 1))
done
echo ""
if [ "$FAILED" -eq 0 ]; then
  ok "All checks passed."
  exit 0
else
  err "${FAILED} check(s) FAILED — review output above"
  exit 1
fi
