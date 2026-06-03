# Claude Code — Project Instructions

---

## Mandatory RCA after every bug fix

A proper RCA must reach a **systemic or design failure**, not just the first link
in the chain. Use 5 Whys. The test: if the root cause were fixed, could this exact
class of bug recur? If yes, you haven't reached the root cause yet.

### RCA template

```
Bug:          [one-line description]

5 Whys:
  Why 1:  [immediate symptom → first cause]
  Why 2:  [first cause → deeper cause]
  Why 3:  ...
  Why N:  [penultimate cause → ROOT CAUSE — a missing contract, rule, or design constraint]

Root cause:   [the systemic/design failure, NOT the code line that was wrong]
Fix applied:  [what was changed to address the root cause directly]
Prevention:   [rule added to CLAUDE.md / contract added to code that prevents recurrence]
Other files:  [files checked for the same root cause]
```

### Example of shallow vs. proper RCA

**Shallow (wrong):**
> Root cause: `source_id` was fetched only in the invitation branch, so other branches
> passed null to `_upsert_person`.

**Proper (correct):**
> Root cause: `_upsert_person` has no input validation. Any caller can pass empty/null
> for required fields and they silently persist as `null` in the state file. The bug
> was structurally invisible at runtime — no warning, no failure, no indication anything
> was wrong until the output was manually inspected.

The difference: the shallow version describes *what went wrong*. The proper version
describes *why it could go wrong silently* — which is the design gap to fix.

---

## Root causes found in this codebase (do not repeat)

### RC-1 — No precondition contracts at state-writing boundaries

**Root cause:** Functions that write to state files (`_upsert_*`) silently accept
null/empty for required fields. Callers can pass incomplete data and it persists
without any runtime signal.

**Fix applied:** Added precondition validation block to `_upsert_person` that logs
`warn` for empty `source_id` (when status ≠ skipped) and `err` + returns 1 for
empty `login`. Violations are visible in CI logs immediately.

**Prevention rules:**
1. Every `_upsert_*` function must open with a precondition block that validates
   all required fields and logs `warn`/`err` on violation.
2. All data fields that appear in a state record must be bound at the TOP of the
   per-item loop body, before any branch. Never compute a required field only
   inside one branch.
3. When a value is available from already-fetched data (e.g., `.id` from the
   members list), use that. Never add a separate API call to fetch something that
   was already returned.

**Template for new `_upsert_*` functions:**
```bash
_upsert_thing() {
  local id="$1" required_field="$2" status="$3"
  # Precondition contract
  [[ -z "$id" ]] && { err "_upsert_thing: id is empty"; return 1; }
  [[ -z "$required_field" || "$required_field" == "null" ]] && \
    warn "_upsert_thing: required_field is empty for $id (status=$status) — check caller"
  case "$status" in
    state_a|state_b|state_c) ;;
    *) warn "_upsert_thing: unexpected status '$status' for $id" ;;
  esac
  # ... rest of function
}
```

---

### RC-2 — No state machine defined before coding lifecycle transitions

**Root cause:** The person lifecycle (`invited → accepted`) was never formally defined.
Without an explicit classification of states as terminal vs transient, the developer
could not reason correctly about loop ordering: both `accepted` and `invited` were
treated as "done, skip" — but `invited` is transient and must allow advancement.

**Fix applied:** Added a state machine comment block directly above `_upsert_person`
classifying every status as TERMINAL or TRANSIENT, with valid transitions listed.

**Prevention rules:**
1. Before writing any loop that manages lifecycle state, define the state machine
   in a comment block:
   - List every status and its classification (TERMINAL or TRANSIENT)
   - List every valid transition with the condition that triggers it
2. TERMINAL states may short-circuit from the state file with no live check.
3. TRANSIENT states must run the live check BEFORE the state-file skip, so the
   state can advance. The canonical order is:
   ```
   1. Terminal state-file check  → skip immediately, no API call
   2. Live existence/membership check → may advance TRANSIENT → TERMINAL
   3. Transient state-file check → skip only if live check did not fire
   4. Creation / write operation
   ```
4. When adding a new status to an existing workflow, explicitly classify it as
   terminal or transient and verify the loop ordering is still correct.

---

### RC-3 — jq on external API responses without error guard

**Root cause:** `jq` called on `gh api` response content that may include extra
non-JSON lines on some runners (warnings, notices). `set -euo pipefail` then kills
the entire script on jq's non-zero exit, turning a data-quality issue into a crash.

**Fix applied:** All jq calls on external API responses use `-rs '.[0].field'`
(slurp, safe for multi-value input) plus `2>/dev/null || true`.

**Prevention rule:** Any `jq` call on a variable that came from `gh api` or any
external HTTP source must use this pattern:
```bash
# WRONG — crashes if gh appends extra output
value="$(echo "$api_response" | jq -r '.field')"

# CORRECT
value="$(echo "$api_response" | jq -rs '.[0].field // empty' 2>/dev/null || true)"
```

---

### RC-4 — jq `//` (alternative operator) silently discards `false` values

**Root cause:** jq's `//` operator treats both `null` **and `false`** as falsy.
`.field // empty` evaluates to `empty` when `.field` is `false`, silently
discarding a valid boolean value. Any config-check or presence-test written
with `//` will invisibly ignore `false` settings.

The concrete failure: `members_can_fork_private_repositories: false` in
`locked_settings` was silently ignored — the lock never fired — because
`jq -r '.members_can_fork_private_repositories // empty'` returned empty.

**Fix applied:** All presence checks on fields that may legitimately be `false`
now use `has()` instead of `//`:

```bash
# WRONG — false // empty = empty; the false value is lost
locked_val="$(echo "$obj" | jq -r '.some_bool_field // empty')"

# CORRECT — has() tests key existence independently of value
locked_val="$(echo "$obj" | jq -r \
  'if has("some_bool_field") then .some_bool_field | tostring else empty end')"
```

**Prevention rule:** Never use `jq`'s `//` to test whether a key is present
when the value may be `false`. Use `has("key")` for existence checks. Apply
the `has()` pattern to every locked-settings lookup and every config-presence
check in the codebase.

---

### RC-5 — `|| echo 'SENTINEL'` inside `$()` conflates exit-code with output content

**Root cause:** `result="$(cmd || echo 'FAILED')"` is assumed to produce either
valid output or exactly `"FAILED"`. That contract breaks whenever `cmd` exits
non-zero *after already writing to stdout* — the sentinel is appended to the
partial output, producing a string that is neither valid JSON nor exactly `"FAILED"`.
Every downstream guard (`== "FAILED"`, `jq -rs '.[0].number'`) is silently bypassed,
leaving dependent variables empty and cascading into broken API calls.

**Fix applied:** Moved the sentinel assignment *outside* `$()`:
```bash
# WRONG — sentinel appended to partial stdout if cmd fails mid-output
result="$(gh api ... 2>/dev/null || echo 'FAILED')"

# CORRECT — assignment exit-code drives the sentinel; partial stdout is discarded
result="$(gh api ... 2>/dev/null)" || result="FAILED"
```

**Prevention rule:** Never use `|| echo 'SENTINEL'` inside a command substitution
for any call that writes to stdout before it can fail (network I/O, `gh api`, `curl`).
Always put the sentinel assignment in the current shell: `cmd="$(external-call)" || cmd="FAILED"`.

**Corollary — `|| echo '[]'` is equally unsafe.** Any array sentinel (`'[]'`, `'0'`,
`'null'`) inside `$()` has the same defect. If the failing command emits partial stdout
first, the captured variable becomes `<partial_output>\n[]` — a two-value stream that
breaks every downstream `jq 'length'` or arithmetic `$((...))` consumer. Use the same
out-of-band assignment pattern for all sentinels.

**Corollary — piping through `jq` is equally unsafe for exit-code detection.** The pattern
`var="$(gh api ... 2>/dev/null | jq -rs '.[0] // empty' 2>/dev/null || true)"` silently
sets `var` to the 404 error JSON even when `gh api` fails. Reason: `gh api` writes the
error response body (`{"message":"Not Found",...}`) to **stdout** on failure. The pipe
feeds this to `jq`, which parses it successfully (exit 0). With `pipefail`, the pipeline
exit code is `jq`'s (0), so `|| true` never fires. `var` is left holding the error JSON,
which is non-empty — so any `[[ -z "$var" ]]` guard is bypassed.

This affects any fetch used to test whether a resource exists (Pages config, team membership,
etc.). The fix is always: fetch without piping and check the exit code out-of-band:
```bash
# WRONG — 404 error JSON body captured; [[ -z "$var" ]] guard bypassed
var="$(gh api "repos/$ORG/$repo/pages" 2>/dev/null | jq -rs '.[0] // empty' || true)"

# CORRECT — non-zero exit from gh api resets var="" regardless of stdout content
var="$(gh api "repos/$ORG/$repo/pages" 2>/dev/null)" || var=""
# Then parse separately when needed:
branch="$(echo "$var" | jq -r '.source.branch // "main"')"
```

---

### RC-6 — `jq --arg` passes large strings as OS arguments, subject to ARG_MAX

**Root cause:** `jq -n --arg body "$var" '{"body":$body}'` passes the value as a
command-line argument. The OS rejects `execve()` with `E2BIG` when arguments exceed
`ARG_MAX` (~2 MB on Linux). `set -euo pipefail` then kills the entire script with
exit 126. The failure is a hard crash with no warning or fallback — large PR review
bodies (long inline code reviews) reliably trigger it.

**Fix applied:** All payload construction with potentially-large string variables now
pipes via stdin instead:
```bash
# WRONG — crashes silently on bodies > ~2 MB
payload="$(jq -n --arg body "$large_var" '{"body":$body}')"

# CORRECT — stdin has no size limit
payload="$(printf '%s' "$large_var" | jq -Rs '{"body":.}')"

# CORRECT — multiple fields: pass only the large one via stdin
payload="$(printf '%s' "$large_var" | jq -Rs --arg title "$title" '{"title":$title,"body":.}')"
```

**Prevention rule:** Never use `jq --arg` for any variable that originates from
external content (API response bodies, PR descriptions, issue text, comment bodies).
Use `printf '%s' "$var" | jq -Rs` for the large field and `--arg` only for small
control values (titles, IDs, status strings).

---

### RC-7 — Idempotency shortcut paths skip side-effect enforcement

**Root cause:** Every idempotency path (state-file skip, body-marker skip) is written
as a "fast-forward shortcut" that re-applies only the side effects the developer thought
of in the moment. There is no enumerated list of invariants that a "fully mirrored" item
must satisfy, so any invariant omitted from a shortcut path is silently skipped on every
subsequent re-run.

The concrete failure: closed PRs found via body-marker on re-runs were never closed in
the target — the marker path reconciled state and synced comments but had no close call.
The PR remained open indefinitely despite being closed/merged in source.

**Fix applied:** Added idempotent `PATCH issues/$n state=closed` to the marker-found
path in the closed PRs loop of `06-mirror-prs.sh`. The GitHub issues endpoint accepts
this call for both real issues and PRs, and it is safe to call repeatedly.

**Prevention rules:**
1. Before writing any idempotency shortcut, enumerate every invariant that must hold
   when the item is "done". Write those invariants as a comment above the shortcut block.
2. Every exit path from the item loop (new creation, state-file skip, marker skip) must
   enforce all invariants — not just the ones the creation path happens to run in order.
3. For closed/merged PRs the invariant set is: body present + closed in target + comments
   synced. Any idempotency path that touches a closed PR must call the close endpoint
   (idempotent; safe if already closed).

---

### RC-8 — `jq -s 'add // []'` on paginated output has no type guard for non-array pages

**Root cause:** `gh api --paginate` can emit non-array JSON (e.g. `{"message":"..."}` error
objects) when any page hits a transient error. `jq -s` wraps all input as an outer array,
`add` merges the elements — but `add` on an array that contains objects produces a merged
object, not an array. `add // []` only substitutes `[]` when `add` returns `null` (empty
input); a merged object is truthy, so `// []` never fires. Downstream `map(.body)` or
`jq 'length'` then operate on an object and crash or produce multi-line output.

The concrete failure: `map(.body // "")` in `_mirror_pr_comments` crashed with
`Cannot index string with string "body"`, and the multiline output from `jq 'length'`
caused `$(( ic_total + rc_total + rv_total ))` to fail with `syntax error in expression`.

**Fix applied (revised):** `gh api --paginate` on REST endpoints that return arrays
emits ONE JSON array per page. `jq -rs` slurps them into `[[page1_items...],[page2_items...]]`.
The outer `.[]` therefore yields **arrays** (one per page), not objects. The pattern
`[.[] | select(type == "object")]` incorrectly filters out the entire page-arrays, producing
`[]` silently. The correct pattern unwraps each page first:

```bash
# WRONG — jq -s 'add // []' crashes when any page is an error object
result="$(gh api ... --paginate | jq -s 'add // [] | map(.field)')"

# WRONG — select(type=="object") on page-level; all page-arrays are silently discarded → []
result="$(gh api ... --paginate | jq -rs '[.[] | select(type == "object") | .field]')"

# CORRECT — select(type=="array") unwraps each page; inner .[] iterates items
result="$(gh api ... --paginate | jq -rs '[.[] | select(type=="array") | .[] | select(type=="object") | .field]')"
```

**Prevention rule:** For REST `--paginate` calls whose responses are arrays-per-page, always use
`select(type=="array") | .[] | select(type=="object")` — two levels of iteration. The outer
`select(type=="array")` also guards against error-object pages (RC-8's original concern).

**Important distinction:**
- REST paginated array endpoints: `[.[] | select(type=="array") | .[] | select(type=="object")]`
- Single-item REST fetch (no `--paginate`): `jq -rs '.[0] // {}'` (returns first and only value)
- GraphQL or object-per-page: `[.[] | select(type=="object")]` (pages are objects, not arrays)

---

### RC-9 — RC prevention rules applied only to code written in the current session, never retroactively enforced

**Root cause:** When a new RC rule is added to CLAUDE.md after discovering a bug, the rule is applied to the specific code path that was broken and to any new code written afterwards. Pre-existing code in other functions or other stages that contains the same pattern is never audited. The rules are documented but have no enforcement scope — they are advisory only within the session that adds them.

The concrete failures discovered in this audit:
- `07-rewrite-cross-references.sh` `_rewrite_item_comments`: `jq -s 'add // []'` (RC-8) and `|| echo '[]'` (RC-5) on paginated comment fetch — never fixed when RC-8 was discovered in stage 06.
- `07-rewrite-cross-references.sh` `_rewrite_repo_items` and `_rewrite_item_comments`: `jq -n --arg b "$new_body"` (RC-6) and `|| echo 'FAILED'` (RC-5) on PATCH calls — never fixed when RC-5/RC-6 were documented.
- `05-mirror-issues.sh` and `06-mirror-prs.sh` `_reconcile_*`: `|| echo '{}'` inside `$()` on single-item `tgt_json` fetch (RC-5) — applied the sentinel-outside rule to paginated calls but not to single-item fetches.

**Fix applied:** All five violations corrected; see B1–B5 above.

**Prevention rules:**
1. After every RC rule is added to CLAUDE.md, immediately `grep -rn` all `mirror/stages/*.sh` and `mirror/lib/*.sh` files for the violation pattern. Fix **all** matches in the same commit — not just the triggering file.
2. The scope of "apply this RC rule" is always the entire codebase, not just the file being changed.
3. RC-5 scope clarification: the sentinel-outside-`$()` rule applies to **all** `gh api` calls piped through `jq`, whether paginated or single-item. A single-item fetch can also write partial stdout before exiting non-zero.

**Grep patterns to run for each rule when adding:**
```bash
# RC-5: sentinel inside $()
grep -rn "|| echo '\(FAILED\|\[\]\|{}\)'" mirror/stages/ mirror/lib/ mirror/validate/

# RC-6: --arg for large variables
grep -rn "jq -n --arg b \|jq.*--arg body \|jq.*--arg body" mirror/stages/ mirror/lib/ mirror/validate/

# RC-8: unsafe paginated flatten
grep -rn "jq -s 'add // \[\]'" mirror/stages/ mirror/lib/ mirror/validate/
```

---

### RC-10 — Secret name changes in one workflow file silently break sibling workflow files

**Root cause:** GitHub Actions workflow files that share the same secrets have no single source
of truth for secret names. When a secret is renamed in one workflow (e.g., `GH_TOKEN` →
`MIGRATION_TOKEN` in `mirror.yml`), sibling files (`validate.yml`) retain the old name
silently — the runner substitutes an empty string with no error, making all API calls
unauthenticated. Validation runs appear to succeed while checking nothing.

The same applies to `with:token:` in the checkout step — it reads `${{ secrets.X }}`
directly (not through env mapping), so an env-level rename has no effect on it.

**Fix applied:**
- `validate.yml` env block: `secrets.GH_TOKEN` / `secrets.GH_TOKEN_SOURCE` → `secrets.MIGRATION_TOKEN` / `secrets.MIGRATION_TOKEN`
- `validate.yml` checkout `with:token:` → `secrets.MIGRATION_TOKEN`
- `validate.yml` `workflow_run` trigger added so validation fires automatically after Mirror completes successfully (eliminating the need to run manually)
- `validate.yml` `chmod +x mirror/stages/*.sh` added defensively

**Prevention rules:**
1. Whenever a secret is renamed in any workflow file, immediately grep all `.github/workflows/*.yml`
   for the old name and update every reference atomically.
2. `with:token:` in checkout steps reads the secret directly — it is NOT affected by env-level
   mappings. Always specify the exact secret name in both `env:` and `with:token:`.
3. Every workflow that shares secrets with another must have a comment naming the canonical
   secret and cross-referencing any sibling file that uses it.
4. Validation workflows must have a `workflow_run` trigger on the workflow that writes state,
   so correctness is verified automatically — not only when an operator remembers to run it.

---

### RC-11 — New script files not audited against existing RC rules at creation time

**Root cause:** `mirror/validate/run-validation.sh` was created and extended without applying
RC-5, RC-8, or RC-9 rules that already existed in CLAUDE.md. The RC-9 grep patterns listed
`mirror/stages/` and `mirror/lib/` but omitted `mirror/validate/`, so the script was invisible
to the mandatory post-rule audit sweep.

The concrete violations found:
- RC-8 in `_check_git_refs`: `jq -s 'add // [] | length'` on `--paginate` output for branches
  and tags. If any page returns a non-array error object, `add` produces a merged object and
  `length` returns a key count, not a branch/tag count.
- RC-5 in seven check functions (`_check_org_settings`, `_check_labels`, `_check_milestones`,
  `_check_issues`, `_check_prs`, `_check_teams`, `_check_actions_variables`): `|| echo 0` / 
  `|| echo '{}'` inside `$()` on direct `gh api` / `ghsrc api` calls.
- Stage number off-by-one in details/warning strings for checks 12–15 (releases through
  outside-collaborators): comments said "stage 10–13" but the correct stage numbers are 11–14.

**Fix applied:** All violations corrected in `mirror/validate/run-validation.sh`:
- RC-8: `_check_git_refs` now uses `jq -rs '[.[] | select(type=="array") | .[] | select(type=="object")] | length'` (two-level iteration; see RC-12 for why `select(type=="object")` alone was wrong).
- RC-5: sentinel assignments moved outside `$()` for all direct `gh api` calls.
- Stage numbers corrected in both the JSON `details` strings and the early-return warning messages.

**Prevention rules:**
1. `mirror/validate/` is now included in all RC grep patterns (updated above).
2. When creating any new script file anywhere in this repo, run the full RC-5/RC-8/RC-9 grep
   sweep against the new file before committing.
3. Stage numbers referenced in validation details strings must match `mirror.yml` stage indices.
   Use `mirror.yml` as the single source of truth; update validation strings atomically when
   stage order changes.

---

### RC-12 — An RC "fix" pattern was itself wrong and propagated to all scripts without empirical verification

```
Bug:          All paginated REST fetches silently returned [] — zero issues, PRs, and comments
              fetched in stages 05, 06, 07, and run-validation.sh. Invisible in normal mode
              (state-file skip fires first) but exposed by continuous=true, which bypasses skips
              and actually fetches items.

5 Whys:
  Why 1:  jq filter [.[] | select(type=="object")] on --paginate output returns [] for every
          REST array endpoint — so stages 05/06/07 found 0 issues and 0 PRs.
  Why 2:  The filter returns [] because jq -rs slurps --paginate output into
          [[page1_items...],[page2_items...]] — outer .[] yields arrays (one per page),
          and select(type=="object") silently discards all of them.
  Why 3:  The filter was applied as the RC-8 "fix" across all stages because it appeared
          in CLAUDE.md as the canonical correct pattern.
  Why 4:  The RC-8 rule was written on reasoning alone, using an incorrect mental model:
          author believed --paginate emits a stream of individual objects, when in fact
          each page is output as a complete JSON array.
  Why 5:  There is no verification step in the rule-creation process. Once a pattern is
          written into CLAUDE.md as "CORRECT", it is treated as ground truth and propagated
          to every matching site without independent testing. The CLAUDE.md update process
          has no gate between "wrote the rule" and "applied the rule everywhere."

Root cause:   RC prevention rules are canonized in CLAUDE.md on reasoning alone, with no
              empirical verification. A plausible-but-wrong pattern can be marked "CORRECT"
              and spread across the entire codebase in one sweep — with no runtime signal,
              because the downstream [] is only an error when code takes a non-skip path.

Fix applied:  All 9 occurrences of the wrong pattern updated to the two-level form:
              [.[] | select(type=="array") | .[] | select(type=="object")]
              Files fixed: 01-invite-people.sh, 10-mirror-teams.sh (×2),
              11-mirror-releases.sh (×2), 12-mirror-branch-protections.sh (×3),
              14-mirror-outside-collaborators.sh, run-validation.sh (×4).
              RC-8 entry in CLAUDE.md revised to document both wrong patterns and the
              correct pattern, with a clear distinction block.

Prevention:   1. Before canonizing ANY jq pattern in CLAUDE.md, test it against synthetic
                 multi-page output to confirm it is non-empty:
                 printf '[{"a":1}]\n[{"a":2}]\n' | jq -rs '[.[] | <PATTERN>]'
                 The result must NOT be [].
              2. When retroactively applying a new RC rule to multiple files, treat the first
                 two or three edits as a hypothesis. After applying, do a quick sanity check
                 (echo output | jq -rs '[<pattern>] | length') before sweeping the rest.
              3. The RC-9 grep for RC-8 now checks for BOTH wrong forms (see updated patterns
                 below).

Other files:  Stages 09 and 13 intentionally use [.[] | select(type=="object")] because their
              endpoints return wrapper objects per page (not arrays). These are EXEMPT — do
              not change them. The distinction is documented in RC-8 above.
```

**Updated RC-8 grep pattern (catches both wrong forms):**
```bash
# RC-8: wrong paginated flatten — catches original jq -s form AND the intermediate wrong fix
grep -rn "jq -s 'add // \[\]'\|select(type==\"object\")\]'" mirror/stages/ mirror/lib/ mirror/validate/ \
  | grep -v "select(type==\"array\")\|13-mirror-actions-variables\|09-other-objects"
```

---

### RC-13 — jq `not` used as prefix function instead of postfix filter

```
Bug:          _clear_crossref_record in mirror/lib/common.sh emitted a compile error on
              every call: "jq: error: not/1 is not defined". The crossref state record
              was never cleared, so stage 07 would skip re-processing bodies that stages
              05/06 had just reconciled.

5 Whys:
  Why 1:  jq reported "not/1 is not defined" and exited non-zero — the filter was never
          applied, so the rewrite-crossrefs.yaml entry was not removed.
  Why 2:  The filter used select(not (expr)) — treating `not` as a prefix function.
          jq's `not` is a postfix filter: it takes its input from the pipeline
          (expr | not), not as a function argument. `not/1` (arity-1 function) does
          not exist in jq.
  Why 3:  The developer wrote the filter by analogy with Python / JavaScript / shell,
          where `not expr` or `!expr` is standard prefix negation. jq diverges from
          every common language on this operator.
  Why 4:  The filter was never tested before being committed. A one-line smoke test
          (echo '{}' | jq 'select(not (.a == 1))') would have caught it immediately.
  Why 5:  There is no step in the development workflow that validates jq filter syntax
          in shell scripts before they reach CI or production. jq expressions embedded
          in bash strings are invisible to shellcheck and similar linters, and are only
          executed when the specific code path is hit at runtime.

Root cause:   jq filter syntax in shell scripts is never validated before runtime. jq has
              operator semantics that differ from every major language (postfix `not`,
              no ternary, etc.) — making it a predictable source of silent human error.
              Without a smoke-test discipline or automated syntax check, errors are only
              discovered when the exact code path is exercised in production.

Fix applied:  Changed select(not (.repo == $r and .target_number == $n))
              to     select((.repo == $r and .target_number == $n) | not)
              in mirror/lib/common.sh line 61.

Prevention:   1. jq `not` is ALWAYS postfix: write (expr) | not, never not(expr).
              2. After writing any non-trivial jq filter in a shell string, run a
                 one-line smoke test before committing:
                 echo '{"items":[{"repo":"r","target_number":1}]}' | \
                   jq --arg r "r" --argjson n 1 '<filter>'
                 The smoke test must produce non-error output.
              3. Grep for the wrong pattern after any jq editing session:
                 grep -rn "select(not " mirror/stages/ mirror/lib/ mirror/validate/

Other files:  grep -rn "select(not " found no other occurrences.
```

---

### RC-14 — "Retry" status applied to a permanently unresolvable condition

```
Bug:          Open PRs from personal forks (e.g. genericaccount-de:feature/X → main)
              were permanently recorded as skipped_open and never appeared in the
              target org, even after multiple mirror runs.

5 Whys:
  Why 1:  Every re-run still logs "head branch not in target — skipping". The PR is
          never created in the target.
  Why 2:  skipped_open means "retry on next run after stage 02 syncs the branch".
          But stage 02 (git push --mirror) only mirrors cyberfabric/REPO →
          constructorfabric/REPO. Personal fork repos (genericaccount-de/REPO) are
          never touched. The branch will never appear in the target org.
  Why 3:  The branch-existence check uses .head.ref (branch name) against the target
          org's branch list. It does not inspect .head.repo.owner.login, so a fork PR
          and a same-repo PR with a missing branch are treated identically.
  Why 4:  skipped_open was designed for same-repo branches that will appear on the
          next stage 02 run. Applying it to fork branches was never considered as a
          distinct case.
  Why 5:  The open-PR strategy (script header, lines 6-18) only addresses "branch
          exists / doesn't exist" with no mention of forks. The design never modelled
          fork PRs as a separate category requiring a different code path.

Root cause:   When a "retry" or "skip" status is introduced, the conditions under which
              a retry CAN succeed are never explicitly enumerated and verified to be
              satisfiable. Fork PRs are a concrete class where the retry condition
              (branch appears in target org) is permanently false — the status should
              never have been applied to them.

Fix applied:  Extract pr_head_owner from .head.repo.owner.login (falling back to
              .head.label's owner prefix when the fork is deleted). If pr_head_owner
              != SOURCE_ORG → pr_from_fork=1 → mirror as open issue immediately with
              a note about the fork. Same-repo branches with a missing head keep
              skipped_open behavior (retry after stage 02 is valid for them).

Prevention:   1. Before introducing any "skip and retry later" status, explicitly
                 enumerate the condition that makes retry succeed. If that condition
                 can be permanently false for a subset of items, that subset needs a
                 separate immediate-fallback path.
              2. For every PR-related code path, check .head.repo.owner.login to
                 distinguish same-repo branches (owner == SOURCE_ORG) from fork
                 branches (owner != SOURCE_ORG). They require different handling.
```

---

## Pre-fetch over per-item API calls

When a loop needs to check membership/existence for N items, fetch the full set
once before the loop. Never call `gh api` inside a loop for a check that can be
answered from a pre-fetched list.

```bash
# WRONG — N API calls, also cannot detect status changes from last run
while ...; do
  code="$(gh api "orgs/$ORG/members/$login" -i | head -1 | awk '{print $2}')"
done

# CORRECT — 1 call, enables stale-state refresh, O(1) per-item lookup
members_lower="$(gh api "orgs/$ORG/members" --paginate --jq '.[].login' \
  | tr '[:upper:]' '[:lower:]')"
while ...; do
  if echo "$members_lower" | grep -qx "$login_lower"; then ...
done
```

---

### RC-15 — Import-mode identifier derived from source org not restored from state

```
Bug:          cf-mirror markers and attribution headers contained an empty SOURCE_ORG
              in import mode, producing markers like "<!-- cf-mirror: /repo#7 -->" instead
              of "<!-- cf-mirror: cyberfabric/repo#7 -->". Future full-mode runs could not
              match these malformed markers, creating duplicate issues/PRs.

5 Whys:
  Why 1:  _build_issue_body / _build_pr_body embed $SOURCE_ORG directly into the
          cf-mirror marker string. With an empty var the marker is structurally broken.
  Why 2:  preflight() only requires SOURCE_ORG when reads_source() is true (i.e., full
          or export modes). Import mode deliberately skips the SOURCE_ORG check because
          it contacts no source API.
  Why 3:  SOURCE_ORG is not purely a credential — it is also an identifier embedded in
          every cf-mirror marker, and markers must be stable across modes.  The
          credential/identifier dual use was not recognized when writing preflight.
  Why 4:  When MIRROR_MODE was designed (export=snapshot, import=replay), the assumption
          was "import needs only target creds". The need to reproduce the EXACT same
          marker string — which encodes the SOURCE_ORG — was not enumerated as a
          constraint of the import path.
  Why 5:  No contract exists stating "these values must be identical across export and
          import runs", so no verification was done that they would be.

Root cause:   The export/import split was designed around credential requirements only,
              not around ALL values needed at import time. SOURCE_ORG is a value the
              import path needs not for authentication but for marker consistency — this
              dual-purpose role was undocumented and therefore unguarded.

Fix applied:  In _import_all_issues (stage 05) and _import_all_prs (stage 06), if
              SOURCE_ORG is unset, derive it automatically from .meta.source_org stored
              in the first state file (written by state_init at export time). A warning
              is emitted if it cannot be derived.

Prevention:
1. When splitting a pipeline into export/import phases, enumerate ALL values the import
   phase needs — not only tokens/creds, but also string identifiers embedded in produced
   artifacts (markers, URLs, state keys). Each such value must be either: (a) provided
   via env at import time, or (b) stored in state at export time and auto-derived at import.
2. Every body/marker builder that embeds a "source" identifier must be audited against
   the import path. If the builder is called at import time, the source identifier must
   be verifiably available.
3. The canonical storage for cross-mode identifiers is .meta.source_org / .meta.target_org
   in the state file (written by state_init at export time). Import-mode entry points that
   need SOURCE_ORG should read it from state via:
     SOURCE_ORG="$(jq -r '.meta.source_org // empty' "$state_file")"
```

---

### RC-16 — Implicit dynamic-scope variable access in top-level functions

```
Bug:          _upsert_pr_export (stage 06) used $repo_name without declaring it as a
              parameter, relying on bash dynamic scoping to inherit it from the calling
              function's local variable. If _upsert_pr_export were ever called from
              outside _export_repo_prs's call chain, $repo_name would be empty and a
              wrong source_url would be stored in state.

5 Whys:
  Why 1:  _upsert_pr_export uses --arg repo "$repo_name" in its jq call but does not
          declare repo_name as a local or accept it as a function parameter.
  Why 2:  The function was written alongside its only caller (_export_one_pr, nested
          inside _export_repo_prs). The author relied on bash dynamic scoping — the
          local $repo_name from _export_repo_prs was accessible transitively.
  Why 3:  Bash dynamic scoping makes any local variable visible to all callees
          in the call stack. This works as long as the call chain is maintained, but
          it is invisible to future maintainers and IDE tooling.
  Why 4:  No code review rule or convention exists in this codebase mandating that
          top-level functions declare all inputs as explicit parameters.
  Why 5:  The function was treated as a "private helper" without formalizing that
          contract in its signature.

Root cause:   Top-level bash functions that rely on ambient dynamic-scope variables have
              an undeclared implicit contract with their callers. The contract is
              invisible in the function signature, invisible to bash -n syntax checking,
              and silently broken (empty string substitution) when the call chain changes.

Fix applied:  Added repo_name as the second explicit parameter to _upsert_pr_export.
              Updated the single call site (_export_one_pr) to pass "$repo_name".

Prevention:
1. Every top-level bash function must declare ALL values it reads as either:
   (a) function parameters  $1, $2, ... (positional)
   (b) well-known globals explicitly documented in common.sh (SOURCE_ORG, TARGET_ORG,
       DRY_RUN, MIRROR_MODE, INVITE_MEMBERS, MIRROR_CONFIG, REPO_ROOT)
   Any other value accessed without being declared in one of these two ways is a bug.
2. "Private" helpers that are defined inside another function body (bash nested functions)
   are acceptable as closures over their parent's locals. Top-level functions are NOT
   closures and must not access parent locals implicitly.
3. grep for the pattern: functions that reference $[a-z_]* where those vars are not in $@
   and not in the approved globals list. Run this check after writing new helper functions.
```

---

### RC-17 — Fixed-width numeric glob silently drops items beyond the width

```
Bug:          state_unsplit reassembled large state files using the glob
              "${whole}".part[0-9][0-9] — matching EXACTLY two digits. A file split
              into >99 parts would have part100, part101, ... silently excluded from
              reassembly, losing every item in those parts with no error.

5 Whys:
  Why 1:  The reassembly glob hard-coded two digit positions ([0-9][0-9]).
  Why 2:  Parts are written with printf '%02d' (min-width 2), so the author's mental
          model was "always 2 digits". %02d is a MINIMUM width, not a maximum — part
          100 prints as "100" (3 digits) and no longer matches the 2-digit glob.
  Why 3:  The glob and the printf format were written together and assumed to be
          symmetric, but min-width formatting and fixed-width matching are NOT inverses.
  Why 4:  Splitting was only ever tested on files producing ≤22 parts, so the >99 case
          was never exercised — the data loss is invisible until a file is big enough.
  Why 5:  There was no test for the boundary (a synthetic >99-part file), and the
          reader/writer width contract was never written down.

Root cause:   A producer using minimum-width formatting paired with a consumer using
              fixed-width matching. The two silently disagree once values exceed the
              fixed width, and the failure mode is silent data loss (missing items),
              not an error.

Fix applied:  Replaced all fixed-width part globs with _state_part_files(), which
              matches <whole>.part<any-digits>, validates the suffix is numeric, and
              sorts NUMERICALLY (10#$num) so part2 < part10 < part100. Used in
              state_unsplit and the stale-part cleanup in state_split_if_needed.
              Added a manifest-count guard: state_unsplit refuses to reassemble when
              the number of parts found != the count recorded in <whole>.parts
              (catches truncated/partial part sets from an interrupted checkout).

Prevention:
1. Never pair printf '%0Nd' (min-width) with a fixed-width glob ([0-9]{N}). If you
   zero-pad for sorting, either (a) match variable width and sort numerically, or
   (b) cap the count and assert it. Variable-width + numeric sort is the safe default.
2. Any "split a collection into N artifacts then recombine" feature MUST have a test
   that crosses the width boundary (>99 parts for 2-digit, >9 for 1-digit).
3. Recombination from multiple files must verify completeness against a recorded count
   (manifest), never trust "whatever the glob happened to match".
```

---

### RC-18 — New storage format not retrofitted to ALL existing readers (only the obvious ones)

```
Bug:          When state-file splitting was added, the import paths (stages 05/06) were
              updated to reassemble parts, but two OTHER readers were missed:
              (a) stage 07 build_number_maps() globbed state/{issues,prs}/*.yaml directly,
                  so a split repo contributed NO source→target number mappings and its
                  cross-references were never rewritten;
              (b) validation _check_assignees() globbed state/issues/*.yaml, so a split
                  repo's pending assignees were silently uncounted (validation says "passed"
                  while work remains).

5 Whys:
  Why 1:  build_number_maps and _check_assignees still used raw *.yaml globs.
  Why 2:  The split rollout updated the files that obviously iterate repos (the import
          loops), but these two helpers iterate the same dirs from a different call site
          and were not on the author's mental list.
  Why 3:  There was no enumeration of ALL consumers of state/issues + state/prs before
          changing the storage format — the change was applied reader-by-reader from memory.
  Why 4:  A storage-format change has a blast radius equal to "everything that reads that
          path", but no grep-sweep was run to enumerate that set.
  Why 5:  Same class as RC-9: a cross-cutting rule/format change is applied only to the
          code in front of the author, never swept across the whole repo.

Root cause:   A storage-layer format change (whole file → possibly-split file) was rolled
              out per-consumer from memory instead of by enumerating every reader of the
              affected paths first. Missed readers fail SILENTLY (a split repo just looks
              empty to them) — the worst kind, because nothing errors.

Fix applied:  Fixed build_number_maps (stage 07) and _check_assignees (validation) to use
              state_repo_names + state_unsplit like every other consumer. Re-swept the
              whole repo for raw globs over the issue/PR dirs; the only remaining *.yaml
              globs are over NON-split dirs (repos, releases, branch-protections,
              outside-collaborators — none call state_split_if_needed).

Prevention:
1. Before changing how ANY state path is stored, run a grep sweep for every reference to
   that path across mirror/stages, mirror/lib, mirror/validate, mirror/tools — and fix
   ALL of them in the same change. Storage-format changes are whole-codebase changes.
2. The canonical iteration over a possibly-split state dir is ALWAYS:
     while read repo; do sf="$dir/$repo.yaml"; state_unsplit "$sf"; [[ -f $sf ]] || continue; ...
     done < <(state_repo_names "$dir")
   A bare  for f in "$dir"/*.yaml  over state/issues or state/prs is a bug.
3. Only state/issues and state/prs are split (only stages 05/06/08 call
   state_split_if_needed). If a NEW stage starts splitting another dir, every reader of
   that dir must be converted to the state_repo_names pattern in the same change.
```

---

### RC-19 — `--argjson` fed a value that can be empty aborts jq and corrupts idempotency

```
Bug:          In stage 15 (projects import), after creating a project in the target the
              code recorded the idempotency marker via:
                state_update ... --argjson tn "$pnum"
              where $pnum is the project NUMBER parsed from the create response. When the
              GraphQL response omitted the number (or it was null), $pnum="" and jq aborted
              with "invalid JSON text passed to --argjson". Under `set -e` this killed the
              stage AFTER the project was already created in the target but BEFORE the
              marker was persisted — so the next run created the project AGAIN (duplicate),
              because projects (unlike issues/PRs) have no body marker to dedup against.

5 Whys:
  Why 1:  --argjson requires syntactically valid JSON; an empty string is not valid JSON,
          so jq exits non-zero and `set -e` aborts the stage.
  Why 2:  $pnum was assumed to always be a number, but it is parsed from an API response
          with `// empty`, which yields "" when the field is absent/null.
  Why 3:  The idempotency marker was keyed on the project NUMBER (a secondary, optional
          field) instead of the project node ID (the authoritative field that always
          exists on a successful create).
  Why 4:  The marker was persisted only at the END of per-project work (after fields +
          drafts), so any failure before that point — including the --argjson crash —
          left the target mutated but the state unmarked → guaranteed duplicate on re-run.
  Why 5:  There was no contract that (a) idempotency markers must be written immediately
          after the irreversible create, and (b) values passed to --argjson must be
          proven non-empty/valid-JSON at the call site.

Root cause:   Two compounding design gaps: (1) an optional/derived field (number) was used
              as the idempotency key instead of the always-present authoritative one (node
              id); (2) the marker was persisted late (after more fallible work) rather than
              immediately after the irreversible target mutation. The --argjson crash was
              just the trigger that exposed both.

Fix applied:  - _gql_create_project defaults an absent number to 0 (never empty).
              - Store target_id (node ID) as the authoritative marker; persist it
                IMMEDIATELY after create, before fields/drafts.
              - Idempotency skip keys on target_id, not target_number.
              - _mark_project_imported passes all values via --arg (string) with in-jq
                `tonumber? // 0`, so an unexpected empty value can never abort jq.
              - Export merge preserves target_id across re-export.

Prevention:
1. Idempotency markers must key on the resource's STABLE, ALWAYS-PRESENT identifier
   (node id / immutable id), never on an optional or human-facing field (number, slug).
2. Persist the idempotency marker IMMEDIATELY after the irreversible create that produces
   it — never after additional fallible steps. An interrupted run must never be able to
   re-create an already-created resource.
3. Never pass a possibly-empty / possibly-non-JSON value to `jq --argjson`. Either prove
   it is valid JSON at the call site, or pass it as `--arg` (string) and convert inside
   the filter with `tonumber? // <default>`. This applies to every --argjson in the repo.
4. Resources with NO content-embedded marker (projects, and anything created via an API
   that doesn't let you store a cf-mirror comment) rely ENTIRELY on the local state marker
   for dedup — so rules 1–2 are mandatory, not best-effort, for them.
```

---

### RC-20 — New mutating gh form (GraphQL mutation) would have bypassed the write-throttle

```
Bug:          Stage 15 import issues GraphQL MUTATIONS (createProjectV2, etc.) via
              `gh api graphql -f query='mutation{...}'`. These carry no --method flag, so
              the throttle engine's _is_write_args returned false and every project/field/
              draft mutation would have run UN-throttled — exactly the silent rate-cap
              violation the write-throttle contract (rule #3) warns about.

5 Whys:
  Why 1:  _is_write_args detected writes only by `--method POST|PATCH|PUT|DELETE` and
          `gh release` subcommands. GraphQL mutations match neither.
  Why 2:  When the throttle engine was written, the only writes in the codebase were REST
          (--method) and release uploads; no GraphQL mutation existed yet.
  Why 3:  Adding the first GraphQL mutation (stage 15 import) introduced a new mutating
          invocation FORM that the detector had never been taught about.
  Why 4:  CLAUDE.md write-throttle rule #3 explicitly says any new mutating gh form MUST
          extend _is_write_args — but that rule is only honored if the author recalls it
          while adding the new form.
  Why 5:  There is no automated check that every target-write path is throttle-detected;
          coverage depends on memory.

Root cause:   Write-detection is an allowlist of known mutating forms. Any newly introduced
              form is invisible to it until explicitly added, and the failure is silent
              (un-throttled writes succeed until GitHub issues a 403).

Fix applied:  Extended _is_write_args to classify `gh api graphql` calls whose query value
              begins with "mutation" (after stripping a leading "query=" and whitespace)
              as writes. Verified: graphql queries → read, graphql mutations → WRITE.

Prevention:
1. (Reaffirms write-throttle rule #3.) Any new mutating `gh` invocation form — a write
   without --method, a new subcommand, a GraphQL mutation — MUST be added to
   _is_write_args in the same change, with a unit check that it classifies as a write.
2. Prefer routing all GraphQL mutations through helper functions named `_gql_*` so a
   grep for mutation call sites is easy to audit against _is_write_args coverage.
3. When adding the FIRST instance of a new write transport (GraphQL, git push via gh,
   etc.), add an explicit _is_write_args test case for it alongside the existing ones.
```

---

### RC-21 — `set -u` crash from a helper that reads a global which can be unset (not just empty)

```
Bug:          _apirate_log_path (API-rate visibility) tested `[[ -z "$APIRATE_LOG" ]]`.
              The var is given a default at source time via "${APIRATE_LOG:-}", so it is
              normally defined — but if any code path UNSETS it, the bare $APIRATE_LOG
              reference aborts under `set -u` with "APIRATE_LOG: unbound variable".

5 Whys:
  Why 1:  The function dereferenced $APIRATE_LOG without the :- fallback.
  Why 2:  A source-time default assignment was assumed to guarantee the var is always set,
          so the function "didn't need" its own guard.
  Why 3:  Source-time defaults only hold until something unsets the var; a robust function
          must not depend on global initialization state it doesn't control.
  Why 4:  `set -u` turns "read of an unset var" into a hard crash, so any unguarded global
          read is a latent abort, not a silent empty string.
  Why 5:  There is no convention that every global read inside a reusable helper uses
          "${VAR:-}" regardless of whether a default was set elsewhere.

Root cause:   A reusable helper depended on ambient global-initialization state instead of
              defending its own reads. Under `set -u` that is a latent crash triggered by
              any caller that unsets (or fails to set) the global.

Fix applied:  `[[ -z "${APIRATE_LOG:-}" ]]` — the same :- guard already used elsewhere in
              common.sh for optional globals. (Mirrors RC-21-adjacent fix in state_init for
              TARGET_ORG.)

Prevention:
1. Inside any reusable function, read an optional/overridable global as "${VAR:-}" (or
   "${VAR:-default}"), NEVER bare "$VAR" — independent of any source-time default. This
   is mandatory while `set -u` is active (it always is here).
2. After adding a new overridable global + its helper, test the helper with the global
   UNSET (`unset VAR; (set -u; helper)`) — not just empty.
```

---

### RC-22 — awk numeric filter trusted untrusted field as a number (count/total mismatch)

```
Bug:          apirate_report counted events in the rolling 60m window with awk
              `$1 >= cutoff`. A malformed log line (non-numeric $1, e.g. "garbage")
              passed this test due to awk's string-vs-number coercion, so it was counted
              in `total` but matched no category — producing a report where total did not
              equal the sum of the categories, and keeping garbage during the prune.

5 Whys:
  Why 1:  `$1 >= cutoff` in awk compares as STRINGS when $1 is non-numeric, and a string
          like "garbage" compares as >= a numeric cutoff, so the line was accepted.
  Why 2:  The filter assumed every line's $1 is a valid epoch, with no validation.
  Why 3:  The log is append-only and could in principle contain a partial/garbled line
          (interrupted write, manual edit, concurrent process), but the reader treated it
          as always-well-formed.
  Why 4:  Counting and pruning shared the same predicate, so a too-loose predicate both
          miscounted AND failed to clean up the bad line.
  Why 5:  No test fed the reporter a malformed line, so the coercion behavior was unseen.

Root cause:   A numeric comparison was applied to a field that was never validated as
              numeric, relying on awk's permissive coercion. Derived totals then diverged
              from their components, and bad data persisted.

Fix applied:  Predicate is now `($1 ~ /^[0-9]+$/) && ($1 + 0 >= cutoff)` — validate the
              epoch is purely numeric first, then compare as a number. Malformed lines are
              excluded from counts AND dropped during the prune.

Prevention:
1. Before a numeric comparison on a field parsed from a file, validate it is numeric
   (`/^[0-9]+$/`) and force numeric context (`+ 0`). Never rely on awk/shell coercion to
   "do the right thing" with untrusted input.
2. When a reported TOTAL is derived alongside per-category counts, add a test that asserts
   total == sum(categories), including a malformed-input case.
```

---

### RC-23 — A read-path reassembly mutated the operator's on-disk split layout (incl. in dry-run)

```
Bug:          state_unsplit reassembles a split state file's parts into the whole file
              AND deletes the parts + manifest. The import paths (stages 05/06) call it on
              every repo before reading. Running an import — even MIRROR_MODE=import
              --dry-run for TESTING — therefore permanently merged the operator's
              deliberately-split state/prs/*.yaml.partNN files back into single large files
              (one of them 203 MB), undoing the split and re-introducing the >100 MB
              GitHub-unpushable file the split existed to prevent.

5 Whys:
  Why 1:  state_unsplit's success path unconditionally did `rm -f "${parts[@]}" "$manifest"`.
  Why 2:  Reassembly was modeled as "merge then consume parts" — correct for a REAL import,
          but state_unsplit is also invoked on read-only / dry-run / testing paths.
  Why 3:  The function had a single destructive behavior regardless of whether the caller
          was actually going to consume the data or just read it transiently.
  Why 4:  dry-run's "no disk mutation" contract was never applied to state_unsplit (same
          class as RC-19/BUG-G: a helper mutated disk in dry-run).
  Why 5:  The on-disk split layout is operator-managed state (it represents a deliberate,
          committed choice), but no code treated it as something that must survive a
          read/dry-run untouched.

Root cause:   A helper used on BOTH "just read it" and "consume and finalize it" paths had
              only the destructive (consume) behavior, and ignored DRY_RUN. Any read-only
              or test invocation silently rewrote operator-managed on-disk layout.

Fix applied:  state_unsplit still produces the whole file (so readers work), but the
              `rm -f parts + manifest` is now guarded by `[[ "${DRY_RUN:-0}" -eq 0 ]]`. In
              dry-run the parts + manifest SURVIVE; a real run consumes them as before.
              Verified: dry-run keeps 2/2 parts; real run consumes them and reassembles.
              (Operator's 4 split repos were re-split immediately via the manual tool.)

Prevention:
1. Any helper that both READS and CONSUMES/FINALIZES a resource must not destroy the
   source form on a read-only or dry-run path. Gate destructive cleanup behind
   `[[ "${DRY_RUN:-0}" -eq 0 ]]`.
2. On-disk split layout (parts + manifest) is OPERATOR-MANAGED, COMMITTED state. Treat it
   like the working tree: a dry-run / test must leave it byte-for-byte unchanged.
3. NEVER run an import (even --dry-run) against the real state/ tree purely to "test" a
   change. Test against a COPY (REPO_ROOT=/tmp/...) or with stubbed inputs. Validation
   runs must not mutate committed state.

   CAVEAT discovered later: stage scripts hard-set `REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"`
   at the top, so passing `REPO_ROOT=/tmp/...` on the command line is IGNORED — the script
   reads the real `state/` tree regardless. To truly isolate a test you must copy the WHOLE
   repo elsewhere and run the copy's script, or stub `gh`/`ghsrc`. (A dry-run against the
   real tree still mutates `meta.last_run_at` and can trigger `state_unsplit`.)
```

---

### RC-24 — "completed" status set regardless of per-item POST failures (silent loss masked as done)

```
Bug:          _import_pr_comments / _import_issue_comments posted N serialized
              comments, incrementing `posted` only on success, but then called
              _update_(pr_)comments_status "...done" "$posted" UNCONDITIONALLY after
              the loop. If some POSTs failed (token expired mid-run, transient 5xx),
              the item was marked comments_status=done with posted<total. The outer
              import loop skips any item whose comments_status==done, so the missing
              comments were NEVER retried — silent data loss recorded as success.

5 Whys:
  Why 1:  The terminal status write was outside any "did everything succeed?" guard.
  Why 2:  `posted` (success count) and the done-marker were decoupled — the marker
          did not depend on posted == total.
  Why 3:  Failures only produced a warn line; they did not feed back into the
          completion decision (no failure counter).
  Why 4:  The resumable design ("skip the first `posted` items on re-run") was built
          for clean interruption (process killed) but not for partial failure WITHIN
          a completed run — those are different: a clean kill never writes done.
  Why 5:  No invariant was written stating "a TERMINAL/done status may only be set
          when zero sub-operations failed" (parallels RC-7: every exit path must
          enforce all invariants).

Root cause:   A terminal/idempotency-skip status (comments_status=done) was treated as
              "the loop finished" rather than "the loop finished AND every item
              succeeded". Done is an invariant claim (all comments present); setting it
              after partial failure is a false claim that suppresses all future retries.

Fix applied:  Added a `failed` counter in both _import_pr_comments and
              _import_issue_comments. On any failure: increment `failed`, stop advancing
              the resumable `posted` prefix. After the loop: mark "done" ONLY when
              failed==0; otherwise mark "in_progress" + a loud WARN, so the next run
              retries from the successful prefix.

Prevention:
1. A "done"/terminal/"skip on re-run" status may be written ONLY on a path that has
   proven every sub-operation succeeded (a zero-failure guard). If anything failed,
   write a non-terminal status so a re-run retries.
2. Any loop that POSTs N items and records aggregate completion MUST track failures and
   gate the terminal status on failures==0 — never set it unconditionally after the loop.
3. KNOWN REMAINING (same class, NOT in the reported scope, lower impact): the FULL-mode
   _mirror_issue_comments / _mirror_pr_comments and the reconcile-mode comment functions
   set comments_status=done after warn-only failures too. They are partly protected
   because they re-check per-comment cf-mirror markers before posting (so a re-run that
   reaches them re-posts the missing ones) — but the outer loop's done-skip can still
   short-circuit them. Apply the failed-counter guard there too when next touching them.
```

---

### RC-25 — `gh api ... | jq` (pipe-through-jq) recurred in newly-added code despite RC-5

```
Bug:          New code added after RC-5 reintroduced the exact RC-5-corollary defect in
              several places: stage 15 GraphQL mutation helpers (_gql_create_field,
              _gql_add_draft, _gql_target_org_id, _gql_create_project), stage 13 target
              variable existence checks, stage 07 target issue body fetch, and stage 09
              webhook existence checks. In every case `gh api ... 2>/dev/null | jq ...`
              let gh's non-zero exit and its error-body-on-stdout be swallowed by jq,
              so a 403/404/scope/GraphQL-error was indistinguishable from "empty result".
              Concrete harms: duplicate variable/webhook creation, silent half-imported
              projects, and a deleted target issue recorded as "successfully rewritten".

5 Whys:
  Why 1:  The convenient one-liner `gh api ... | jq` was used for reads/mutations whose
          result feeds an existence/dedup/extract decision.
  Why 2:  RC-5's corollary ("piping through jq is unsafe for exit-code detection") was
          documented for REST fetches but not internalized for (a) GraphQL mutations and
          (b) every new existence-check site — it was treated as a stage-05/06-era issue.
  Why 3:  GraphQL adds a second failure channel RC-5 didn't call out: HTTP 200 + a
          top-level {"errors":[...]} body. Neither the exit code NOR an empty .data
          field alone distinguishes "permission denied" from "nothing there".
  Why 4:  No grep-gate ran for the RC-5 pattern when stages 13/15 and the new checks
          were written (same class as RC-9/RC-11: rules applied only to code in front of
          the author, not swept across new code).
  Why 5:  There was no shared helper, so each site re-implemented the unsafe pattern.

Root cause:   RC-5 was a rule without an enforcement mechanism for NEW code or for the
              GraphQL transport. The unsafe idiom is shorter than the safe one, so it
              keeps reappearing wherever a new existence/extract check is written.

Fix applied:  - All four stage-15 GraphQL helpers now capture the response out-of-band and
                call a new _gql_warn_errors() that surfaces .errors[0].message (so a
                permission/scope failure is loud, not silent-empty).
              - Stage 13 target-var checks fetch out-of-band and SKIP apply on fetch
                failure (rather than treating [] as "none exist" → duplicates).
              - Stage 07 body fetch is out-of-band; a failed GET → skip + retry-next-run
                (not "no_change" → done).
              - Stage 09 webhook checks fetch out-of-band, ADD --paginate, skip on error.
              - New shared helper gh_flatten_wrapper() for wrapper-object paginated
                endpoints (secrets/variables) that WARNS on error/short pages (RC-8 + RC-5
                combined) instead of silently truncating.

Prevention:
1. NEVER write `gh api ... | jq ...` (or `ghsrc api ... | jq`) when the result drives an
   existence check, dedup, extract-then-decide, or any mutation result. Capture
   out-of-band: `raw="$(gh api ... 2>/dev/null)" || { handle failure }; echo "$raw" | jq ...`.
2. For GraphQL specifically: a 200 response can carry {"errors":[...]} with null .data.
   Always check .errors before trusting an extracted field. Route mutations through a
   helper that warns on .errors (e.g. _gql_warn_errors).
3. On a failed existence/list fetch that feeds dedup, DO NOT proceed as if the list were
   empty (that creates duplicates) — skip the write and warn.
4. Grep gate to run after adding ANY new gh/ghsrc call:
     grep -rn 'gh api .*| *jq\|ghsrc api .*| *jq' mirror/stages/ mirror/lib/ mirror/validate/
   Each hit must be justified (pure logging that tolerates loss) or converted.
```

---

### RC-26 — Long-running progress/status only on stderr → invisible in a busy console

```
Bug:          Progress/ETA and API-rate summaries were emitted only via the stderr log,
              throttled (every 10 items / 15s). During a multi-hour import the console is
              flooded with per-item ok/warn lines, so the operator could not find or
              follow the one line that matters (overall % + ETA + rate).

5 Whys:
  Why 1:  The only sink for progress was the same stderr stream as all other logging.
  Why 2:  The line was additionally throttled, so it appeared rarely amid the noise.
  Why 3:  There was no dedicated, always-current artifact an operator could poll.
  Why 4:  "Show progress" was implemented as "log progress", conflating a STATUS signal
          (latest snapshot, overwrite) with an EVENT stream (append-only log).
  Why 5:  Status and log are different concerns; only the log concern was built.

Root cause:   A status signal (current %/ETA/rate) was delivered through an append-only,
              throttled, noise-sharing event channel instead of a separate
              always-overwritten file the operator can cat/watch.

Fix applied:  progress_tick now OVERWRITES a plain-text state/.progress on EVERY tick
              (cheap, no throttle) with the current progress line plus the latest cached
              API-rate summary. The throttled stderr line is kept as a convenience.
              apirate_report caches its summary to state/.api-rate.summary for inclusion.
              All four runtime files (.progress, .progress.json, .api-rate.log,
              .api-rate.summary) are gitignored. `cat state/.progress` / `watch` to follow.

Prevention:
1. A STATUS value (latest snapshot) belongs in a dedicated file that is OVERWRITTEN each
   update — never only in the append-only/throttled log shared with all other output.
2. Status files are transient runtime scratch: gitignore them and resolve their path via
   "${REPO_ROOT:-.}" with a ":-" guard (RC-21).
```

---

### RC-27 — Helper called with args in the wrong order silently no-op'd (jq options before filter)

```
Bug:          _throttle_set's signature is `_throttle_set <jq-filter> [jq-args...]`
              (it does `local filter="$1"; shift; jq "$@" "$filter" ...`). Two callers
              in the hourly-cap reset path were written as
                _throttle_set --argjson now "$now" '.hour_window_start=$now | ...'
              i.e. jq OPTIONS before the filter. So $1 (filter) became "--argjson",
              the real filter landed in "$@", and the jq invocation was malformed →
              it failed → guarded by `2>/dev/null` and an `else rm -f tmp` → SILENT
              no-op. Net effect: the hourly-window reset NEVER persisted, so
              writes_in_hour grew without bound (observed: 5568) and the hourly cap
              effectively never engaged. The same mistake was about to ship in the new
              AUTORATELIMIT probe.

5 Whys:
  Why 1:  Caller passed jq options before the filter; helper treats $1 as the filter.
  Why 2:  The helper's arg contract (filter-first) wasn't visible at the call site and
          wasn't asserted.
  Why 3:  jq itself ACCEPTS options-before-filter, so the pattern "looks" right to
          someone thinking about jq, not about the wrapper's shift.
  Why 4:  The wrapper swallowed jq's stderr and discarded the temp on failure, so a
          malformed call produced NO error — only a missing state update.
  Why 5:  No test asserted that _throttle_set actually changed the file; the hourly
          cap's correctness was never exercised in a unit test.

Root cause:   A thin wrapper with a positional contract (filter must be $1) silently
              accepted-and-discarded calls that violated it, because it both reordered
              args AND suppressed jq errors. Wrong-order calls became invisible no-ops.

Fix applied:  Reordered all callers to filter-first:
                _throttle_set '<filter>' --argjson now "$now"
              Fixed both pre-existing hourly-cap calls and the new AUTORATELIMIT calls.
              (AUTORATELIMIT's hourly + window logic now actually persists.)

Prevention:
1. A wrapper that takes "<required positional> [pass-through args...]" should put the
   positional FIRST and document it at the definition AND at non-obvious call sites.
   Prefer wrappers whose pass-through args can't be confused with the positional.
2. NEVER suppress the inner tool's stderr in a state-mutating wrapper without also
   surfacing failure some other way. `jq ... 2>/dev/null; else rm tmp` turns a
   malformed call into a silent no-op. At minimum `warn` on the failure branch.
3. After writing/altering a state-mutating helper, add a one-line test that asserts
   the file actually changed (jq read-back), including an args-bearing call.
4. grep gate: `grep -n '_throttle_set --' mirror/lib/common.sh` must return nothing
   (every call is filter-first).
```

---

### RC-28 — AUTORATELIMIT: header-driven adaptive throttling (design note, not a bug)

```
Context:      Operator wanted to push import speed closer to GitHub's real limits
              safely, using the x-ratelimit-* headers / `gh api rate_limit`.

Design decisions (for future maintainers):
1. PRECISION over guessing: when usage crosses AUTORATELIMIT (fraction of limit),
   sleep until the bucket's RESET epoch (+buffer), not a blind exponential ladder.
   The reset epoch is authoritative — no overshoot, never exceeds the cap. The
   exponential ladder survives ONLY as a fallback when reset is unavailable.
2. PRIMARY vs SECONDARY: x-ratelimit-* and `rate_limit` expose only PRIMARY limits
   (core/graphql buckets). The SECONDARY (abuse) limit is NOT in any header or
   endpoint — it surfaces only as 403 + Retry-After. So AUTORATELIMIT handles
   primary; the existing _throttle_on_rate_limit hard-stop handles secondary. Do
   not claim `rate_limit` can detect secondary limits — it cannot.
3. COST control: refresh the snapshot via a PROBE every N writes (default 25), not
   on every call (which would itself consume ~2x quota). `rate_limit` does not
   count against quota, so the probe is free. Probe uses `command gh` to avoid
   recursing through the throttled gh() wrapper.
4. TOKEN hygiene: probe with the same token context as the calls it governs
   (gh = target, ghsrc = source) — they have independent limits.
5. OFF by default (AUTORATELIMIT=0): adaptive throttling must be opt-in; the fixed
   conservative delays remain the baseline.
```

---

### RC-29 — New GitHub API fields (type, sub-issues, issue_field_values) never included in issue migration

```
Bug:          Target issues were missing: issue Type (Bug/Feature/Task), parent/child
              (sub-issue) relationships, and Priority (issue_field_values). These were
              visible in the source org but absent from every created target issue.

5 Whys:
  Why 1:  The issue creation payload in both _mirror_repo_issues (full) and
          _import_repo_issues (import) only sent: title, body, labels, milestone.
          No other fields were included in the POST to /repos/.../issues.
  Why 2:  The stage was written when these fields did not exist in GitHub's API:
            - issue type  — added to REST API in 2024
            - sub-issues  — added to REST API in 2024
            - issue_field_values — repo-level custom fields, added ~2024
  Why 3:  When GitHub added these fields to the API responses (so they appeared in
          exported source_data), the import code was never updated to send them back.
          There was no review of "what new fields does the export now contain that
          import should be sending."
  Why 4:  The mapping of "fields in source_data" → "fields sent in create payload"
          was implicit (only the original fields were coded); new fields silently
          appeared in the exported data but were never wired to the create call.
  Why 5:  No test compared the source issue with the created target issue field-by-field
          to detect gaps; the only validation was "was an issue created" not "does the
          created issue have the same fields as the source."

Root cause:   The issue-creation payload was a FIXED enumeration of known fields written
              at the time of initial development. GitHub continuously adds new issue
              fields to both the API response and the API request. The code had no
              mechanism to detect new fields in source_data and no process to review
              the export-vs-import field coverage when the GitHub API evolves.

Fix applied:  1. type: extracted from source_data.type.name and included in the POST
                 payload for both full-mode and import-mode. Retry-without-type added
                 (type name may not exist in target org) — same pattern as labels/milestone.
                 Affects 444 issues across 8 repos in this org.
              2. parent/child (sub-issues): cannot be set during issue creation because
                 the parent must already exist. New tool mirror/tools/set-sub-issues.sh
                 restores all parent/child relationships in a post-import pass using the
                 source→target number mapping in state files. Affects 199 issues.
              3. issue_field_values (Priority custom field): not fixed — only 4 issues
                 affected; target repo needs matching custom field definitions with
                 compatible IDs (org-specific). Documented as manual-action required.
              4. Project membership: issues appear in Projects V2 via separate stage 15
                 (projects export/import), not via the Issues API. Not a bug in stage 05.

Prevention:
1. When the GitHub API is updated (new fields in issue/PR responses), IMMEDIATELY audit
   stage 05 and 06 to determine if the new field: (a) can be set at create time via the
   Issues API, (b) requires a separate API call after creation, or (c) is read-only.
   Update the create payload and/or add a post-processing step accordingly.
2. After any import run, spot-check at least one target issue against its source by
   comparing all non-null fields in source_data with the created target issue. Any
   field present in source_data but absent in target is a gap to investigate.
3. The field enumeration pattern ("only send these known fields") should be replaced
   with an explicit EXCLUSION list ("send all source_data fields EXCEPT these known
   read-only/server-managed ones"). This is more resilient to API additions.
4. issue_field_values: If new custom issue fields are added at the org level, stage 05
   export must be re-run to capture them, and a post-import tool must be written to
   apply them using the target org's field IDs. Add a warning in the import log when
   issue_field_values is non-empty in source_data but not applied.
```

---

## Write-throttle / abuse-protection contract (non-negotiable)

A central write-throttle engine in `mirror/lib/common.sh` enforces the GitHub
abuse-protection policy. Defaults: 10s after every write, ≤350 writes/hour, a
300s pause every 100 writes, and on 403/429 a hard stop (Retry-After+60s or 900s)
followed by degraded mode (20s/write, pause every 50). All knobs are env-overridable.

**Rules any future code MUST follow:**

1. **Single writer, always.** Never run stages concurrently, never background a
   write, never add a second worker. The engine's counters are file-based but NOT
   lock-safe; two writers corrupt the state and defeat the rate cap.
2. **All target writes go through `gh()`.** Never call `command gh` directly for a
   target write — that bypasses the throttle. `ghsrc` (source reads) is exempt and
   correctly uses `command gh`.
3. **Write detection lives in `_is_write_args`** (matches `--method POST|PATCH|PUT|DELETE`
   and `gh release upload|delete|create|edit`). If you introduce a new mutating gh
   invocation form (e.g. a write without `--method`, or a new `gh` subcommand that
   writes), you MUST extend `_is_write_args` or it will silently go un-throttled.
4. **Throttle state is subshell-safe by being file-based** (`state/.write-throttle.json`).
   Do NOT refactor it into shell variables — nearly every write runs inside
   `result="$(gh api ...)"`, a subshell, where variable mutations are lost.
5. **403/429 is a HARD STOP, not a per-item retry.** Never add a short `sleep N` +
   continue on a rate-limit error — that escalates to stronger secondary limits. The
   engine already paused before returning the failure; stage code only records the
   item as failed (idempotent markers let the next run resume).
6. **Per-call `pause N` in stages is additive and harmless** (more conservative than
   the engine), but the engine — not the inline pauses — is the source of truth for
   the rate cap. Do not rely on inline pauses for abuse protection.

Why a wrapper and not per-stage sleeps (RCA summary): scattering the policy across
14 files guarantees drift — one missed site silently violates the rate cap, and the
violation is invisible until GitHub issues a 403. Centralizing in the single chokepoint
(`gh()`) that every write already passes through makes coverage total and auditable
(`grep -c 'command gh'` must only match `ghsrc` and the wrapper itself).

---

## Token hygiene (non-negotiable)
- `GH_TOKEN` — writes to TARGET org only
- `GH_TOKEN_SOURCE` — reads from SOURCE org only, via `ghsrc` wrapper
- Never commit token values to any file
- Never invite or add to teams: any login listed in `config.json` → `stage_01_invite_people.exclude_logins`
