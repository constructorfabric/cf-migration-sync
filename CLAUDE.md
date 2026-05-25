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
- `GH_TOKEN` — writes to TARGET org (`constructorfabric`) only
- `GH_TOKEN_SOURCE` — reads from SOURCE org (`cyberfabric`) only, via `ghsrc` wrapper
- Never commit token values to any file
- Never invite or add to teams: `dfc-Acronis`, `alexpitsikoulis`, `gaidar`
