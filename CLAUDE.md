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

## Token hygiene (non-negotiable)
- `GH_TOKEN` — writes to TARGET org only
- `GH_TOKEN_SOURCE` — reads from SOURCE org only, via `ghsrc` wrapper
- Never commit token values to any file
- Never invite or add to teams: any login listed in `config.json` → `stage_01_invite_people.exclude_logins`
