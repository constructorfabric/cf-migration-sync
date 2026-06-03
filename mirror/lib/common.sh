#!/usr/bin/env bash
# mirror/lib/common.sh — shared functions for all mirror stages
# Source this file at the top of each stage script:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/../lib/common.sh"

set -euo pipefail

# ---------------------------------------------------------------------------
# Colour codes
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log() {
  echo -e "${CYAN}[$(now)]${RESET} $*" >&2
}

ok() {
  echo -e "${GREEN}[$(now)] OK${RESET} $*" >&2
}

warn() {
  echo -e "${YELLOW}[$(now)] WARN${RESET} $*" >&2
}

err() {
  echo -e "${RED}[$(now)] ERROR${RESET} $*" >&2
}

# ---------------------------------------------------------------------------
# Timing / rate-limit helpers
# ---------------------------------------------------------------------------
pause() {
  local secs="${1:-0.3}"
  sleep "$secs"
}

# ===========================================================================
# Progress / ETA engine
# ===========================================================================
# Shows "% complete + ETA + current repo" periodically during long imports.
# Because export already serialized everything, the TOTAL unit count is known
# up front, so progress and ETA are accurate. ETA is computed from the observed
# wall-clock rate (units actually completed / elapsed seconds) — this naturally
# absorbs the write-throttle delays, batch pauses, and any 403 hard-stops,
# rather than assuming a fixed per-unit cost.
#
# A "unit" is whatever the caller counts (an issue, a PR, a project). The caller
# decides granularity; this engine just tracks done/total over time.
#
# Subshell-safe: state lives in a FILE ($PROGRESS_STATE), because import work
# runs inside  result="$(gh ...)"  subshells where shell-variable mutation is lost.
#
# Usage:
#   progress_begin <total_units> "<label>"        # once, before the work loop
#   progress_tick  [n] [current-repo]             # after each unit (n defaults 1)
#   progress_end                                  # once, after the loop
# progress_tick logs a line only every PROGRESS_EVERY units (default 10) and at
# least PROGRESS_MIN_INTERVAL seconds apart, so it never spams the log.

PROGRESS_EVERY="${PROGRESS_EVERY:-10}"            # log at most every N ticks
PROGRESS_MIN_INTERVAL="${PROGRESS_MIN_INTERVAL:-15}"  # ...and >= this many seconds apart
PROGRESS_STATE="${PROGRESS_STATE:-}"

# Human-readable status file. Unlike the stderr log line (which is throttled and
# easily lost in console noise), this file is OVERWRITTEN on every tick so it is
# always current — `cat state/.progress` or `watch -n5 cat state/.progress` to
# follow a long run. It carries the progress/ETA snapshot AND the latest API-rate
# summary. Gitignored.
PROGRESS_FILE="${PROGRESS_FILE:-}"

# _progress_state_path — lazily resolve the internal JSON state file path.
_progress_state_path() {
  if [[ -z "${PROGRESS_STATE:-}" ]]; then
    PROGRESS_STATE="${REPO_ROOT:-.}/state/.progress.json"
  fi
  echo "$PROGRESS_STATE"
}

# _progress_file_path — lazily resolve the human-readable status file path.
_progress_file_path() {
  if [[ -z "${PROGRESS_FILE:-}" ]]; then
    PROGRESS_FILE="${REPO_ROOT:-.}/state/.progress"
  fi
  echo "$PROGRESS_FILE"
}

# _status_write_file <progress_line> — (re)write the human status file with the
# given progress line plus the most-recent cached API-rate summary line. Called
# on every tick so the file is always current; cheap (no jq, no awk).
_status_write_file() {
  local progress_line="$1"
  local sf; sf="$(_progress_file_path)"
  local rate_line=""
  local rs; rs="$(_apirate_summary_path)"
  [[ -f "$rs" ]] && rate_line="$(cat "$rs" 2>/dev/null || true)"
  # Latest AUTORATELIMIT probe summary (first line only; it has its own 'updated:').
  local rl_line=""
  local rlf; rlf="$(_ratelimit_summary_path)"
  [[ -f "$rlf" ]] && rl_line="$(head -1 "$rlf" 2>/dev/null || true)"
  {
    echo "$progress_line"
    [[ -n "$rate_line" ]] && echo "$rate_line"
    [[ -n "$rl_line"   ]] && echo "$rl_line"
    echo "updated: $(now)"
  } > "$sf" 2>/dev/null || true
}

# _hms <seconds> — format an integer second count as compact "1h 02m 03s".
_hms() {
  local s="${1:-0}"
  (( s < 0 )) && s=0
  local h=$(( s / 3600 )) m=$(( (s % 3600) / 60 )) sec=$(( s % 60 ))
  if (( h > 0 )); then printf '%dh %02dm %02ds' "$h" "$m" "$sec"
  elif (( m > 0 )); then printf '%dm %02ds' "$m" "$sec"
  else printf '%ds' "$sec"; fi
}

# progress_begin <total> <label>
progress_begin() {
  local total="${1:-0}" label="${2:-work}"
  local pf; pf="$(_progress_state_path)"
  mkdir -p "$(dirname "$pf")" 2>/dev/null || true
  jq -n --argjson total "$total" --arg label "$label" --argjson now "$(date +%s)" \
    '{label:$label, total:$total, done:0, start:$now, last_log:0, last_repo:""}' \
    > "$pf" 2>/dev/null || \
    printf '{"label":"%s","total":%s,"done":0,"start":%s,"last_log":0,"last_repo":""}' \
      "$label" "$total" "$(date +%s)" > "$pf"
  if [[ "$total" -gt 0 ]]; then
    log "Progress: starting $label — $total item(s) to process"
    _status_write_file "Progress: 0% (0/${total} ${label}) — ETA — — starting"
  fi
}

# progress_tick [n] [current_repo] — advance the counter by n (default 1) and,
# when due, log "% — done/total — ETA — repo".
progress_tick() {
  local n="${1:-1}" repo="${2:-}"
  local pf; pf="$(_progress_state_path)"
  [[ -f "$pf" ]] || return 0

  # Advance done (and remember the current repo) atomically.
  local tmp; tmp="$(mktemp)"
  jq --argjson n "$n" --arg repo "$repo" \
    '.done += $n | (if $repo != "" then .last_repo = $repo else . end)' \
    "$pf" > "$tmp" 2>/dev/null && mv "$tmp" "$pf" || { rm -f "$tmp"; return 0; }

  local total done start last_log label last_repo now
  total="$(jq -r '.total'    "$pf" 2>/dev/null || echo 0)"
  done="$(jq -r '.done'      "$pf" 2>/dev/null || echo 0)"
  start="$(jq -r '.start'    "$pf" 2>/dev/null || echo 0)"
  last_log="$(jq -r '.last_log' "$pf" 2>/dev/null || echo 0)"
  label="$(jq -r '.label'    "$pf" 2>/dev/null || echo work)"
  last_repo="$(jq -r '.last_repo' "$pf" 2>/dev/null || echo '')"
  now="$(date +%s)"

  [[ "$total" -le 0 ]] && return 0   # unknown total → nothing to show

  # Build the snapshot line (always, on every tick — it's cheap).
  local elapsed=$(( now - start ))
  (( elapsed < 1 )) && elapsed=1
  local pct=$(( done * 100 / total ))
  local eta_str="—"
  if (( done > 0 && done < total )); then
    local remaining=$(( total - done ))
    local eta=$(( elapsed * remaining / done ))
    eta_str="$(_hms "$eta")"
  elif (( done >= total )); then
    eta_str="done"
  fi
  local rate_str=""
  if (( elapsed > 0 )); then
    local ipm10=$(( done * 600 / elapsed ))   # items/min, fixed-point 1 decimal
    rate_str=" — $(( ipm10 / 10 )).$(( ipm10 % 10 ))/min"
  fi
  local line="Progress: ${pct}% (${done}/${total} ${label})${rate_str} — ETA ${eta_str}${last_repo:+ — repo ${last_repo}}"

  # ALWAYS overwrite the human status file (the reliable, easy-to-watch source).
  _status_write_file "$line"

  # Throttle only the STDERR log line: every PROGRESS_EVERY units AND >= MIN_INTERVAL
  # secs apart, but always allow the final (done >= total) line through.
  local due=0
  (( done >= total )) && due=1
  (( done % PROGRESS_EVERY == 0 )) && (( now - last_log >= PROGRESS_MIN_INTERVAL )) && due=1
  [[ "$due" -eq 0 ]] && return 0

  # Record that we logged now.
  tmp="$(mktemp)"
  jq --argjson t "$now" '.last_log = $t' "$pf" > "$tmp" 2>/dev/null && mv "$tmp" "$pf" || rm -f "$tmp"

  log "$line"
}

# progress_end — final 100% line + total elapsed, then clear the state file.
progress_end() {
  local pf; pf="$(_progress_state_path)"
  [[ -f "$pf" ]] || return 0
  local total done start label now
  total="$(jq -r '.total' "$pf" 2>/dev/null || echo 0)"
  done="$(jq -r '.done'   "$pf" 2>/dev/null || echo 0)"
  start="$(jq -r '.start' "$pf" 2>/dev/null || echo 0)"
  label="$(jq -r '.label' "$pf" 2>/dev/null || echo work)"
  now="$(date +%s)"
  if [[ "$total" -gt 0 ]]; then
    local final="Progress: complete — ${done}/${total} ${label} in $(_hms $(( now - start )))"
    log "$final"
    _status_write_file "$final"
  fi
  rm -f "$pf"
}

# ===========================================================================
# Write-throttle engine (GitHub abuse-protection policy)
# ===========================================================================
# Implements the conservative write-throttling policy for issue/PR migration:
#   - exactly one writer (the codebase is already single-threaded; we add no
#     concurrency and this engine assumes none)
#   - a fixed delay AFTER every mutating request (WRITE_DELAY_SECONDS)
#   - a long pause after every BATCH_SIZE_WRITES successful writes
#   - an hourly cap (MAX_WRITES_PER_HOUR) with a sleep until the window resets
#   - 403/429 → HARD STOP for writes: long fallback pause, then DEGRADED mode
#     (slower delay + smaller batch) for the rest of the run
#   - per-write header logging (x-ratelimit-*, retry-after, request id)
#
# CRITICAL DESIGN NOTE — subshell safety:
#   Almost every write in the stages runs inside  result="$(gh api ...)"  which
#   executes in a SUBSHELL. Shell-variable counters set there are lost when the
#   subshell exits. Therefore ALL throttle state lives in a FILE
#   ($THROTTLE_STATE) read/written on each call, and a 403/429 "stop" is a long
#   in-call SLEEP (the parent blocks on the command substitution) rather than an
#   `exit` (which would only kill the subshell, not the migration).
#
# All values are overridable via env (the policy's "safest starting values").
WRITE_DELAY_SECONDS="${WRITE_DELAY_SECONDS:-10}"
DEGRADED_WRITE_DELAY_SECONDS="${DEGRADED_WRITE_DELAY_SECONDS:-20}"
BATCH_SIZE_WRITES="${BATCH_SIZE_WRITES:-100}"
BATCH_PAUSE_SECONDS="${BATCH_PAUSE_SECONDS:-300}"
DEGRADED_BATCH_SIZE_WRITES="${DEGRADED_BATCH_SIZE_WRITES:-50}"
DEGRADED_BATCH_PAUSE_SECONDS="${DEGRADED_BATCH_PAUSE_SECONDS:-300}"
RATE_LIMIT_FALLBACK_PAUSE_SECONDS="${RATE_LIMIT_FALLBACK_PAUSE_SECONDS:-900}"
MAX_WRITES_PER_HOUR="${MAX_WRITES_PER_HOUR:-350}"
MAX_RETRIES="${MAX_RETRIES:-3}"
# Low-watermark for x-ratelimit-remaining: pause until reset when at/below this.
RATELIMIT_MIN_REMAINING="${RATELIMIT_MIN_REMAINING:-50}"

# ---------------------------------------------------------------------------
# AUTORATELIMIT — adaptive throttling driven by GitHub's PRIMARY rate-limit
# headers (x-ratelimit-limit / -remaining / -reset / -resource).
#
#   AUTORATELIMIT=0          → OFF (default). Only the fixed delays + hourly cap
#                              + 403/429 hard-stop apply (unchanged behaviour).
#   AUTORATELIMIT=<0..1>     → ON. When a bucket's usage (used/limit) reaches or
#                              exceeds this fraction (e.g. 0.8 = 80%), the engine
#                              SLEEPS until that bucket's reset time (+ buffer),
#                              so usage falls back under the threshold before
#                              continuing. This is precise (the reset epoch is
#                              authoritative) — no overshoot, never blows the cap.
#
# How the snapshot is obtained: a cheap PROBE (`gh api -i rate_limit`) every
# AUTORATELIMIT_PROBE_EVERY writes refreshes a cached snapshot of the core (REST)
# and graphql buckets into the throttle state. The per-write gate reads the
# cached snapshot, so we do NOT double every API call or touch caller stdout.
#
# NOTE ON LIMITS: x-ratelimit-* and `rate_limit` report only the PRIMARY limits.
# The SECONDARY (abuse) limit is NOT exposed by any header or endpoint — it only
# manifests as a 403 with Retry-After, which the existing _throttle_on_rate_limit
# hard-stop already handles. AUTORATELIMIT therefore complements, not replaces, it.
AUTORATELIMIT="${AUTORATELIMIT:-0}"
AUTORATELIMIT_PROBE_EVERY="${AUTORATELIMIT_PROBE_EVERY:-25}"
# RATELIMIT_SHOW=1 → run the (quota-free) rate_limit probe purely for VISIBILITY
# (console line + state/.rate-limit + .progress) even when AUTORATELIMIT=0. It
# does NOT change throttle behaviour — it only displays how close we are to the
# primary limits. When AUTORATELIMIT>0 the gate already probes, so this avoids a
# redundant second probe.
RATELIMIT_SHOW="${RATELIMIT_SHOW:-0}"
AUTORATELIMIT_RESET_BUFFER="${AUTORATELIMIT_RESET_BUFFER:-15}"   # secs added to reset
# Bounded exponential fallback (only used if a reset epoch is unavailable):
AUTORATELIMIT_FALLBACK_BASE="${AUTORATELIMIT_FALLBACK_BASE:-4}"  # 4,16,64,256...
AUTORATELIMIT_FALLBACK_MAX="${AUTORATELIMIT_FALLBACK_MAX:-300}"  # cap a single sleep

# Throttle state file (JSON). Lives under state/ so it survives across stages in
# a run but is reset per fresh checkout. Path is set lazily in _throttle_init.
THROTTLE_STATE="${THROTTLE_STATE:-}"

# _throttle_init — create the state file if missing. Safe to call repeatedly.
_throttle_init() {
  if [[ -z "$THROTTLE_STATE" ]]; then
    THROTTLE_STATE="${REPO_ROOT:-.}/state/.write-throttle.json"
  fi
  mkdir -p "$(dirname "$THROTTLE_STATE")" 2>/dev/null || true
  if [[ ! -f "$THROTTLE_STATE" ]]; then
    jq -n --argjson now "$(date +%s)" \
      '{writes_total:0, writes_in_batch:0, hour_window_start:$now,
        writes_in_hour:0, degraded:false,
        arl_probe_at:0, arl_fallback_step:0}' > "$THROTTLE_STATE" 2>/dev/null || \
      printf '{"writes_total":0,"writes_in_batch":0,"hour_window_start":%s,"writes_in_hour":0,"degraded":false,"arl_probe_at":0,"arl_fallback_step":0}' \
        "$(date +%s)" > "$THROTTLE_STATE"
  fi
}

# _arl_probe — refresh the cached primary-rate snapshot via `gh api -i rate_limit`.
# Parses the core (REST) and graphql buckets and stores their used/limit/reset.
# Cheap (one extra call) and only invoked every AUTORATELIMIT_PROBE_EVERY writes.
# Uses `command gh` directly to avoid recursion through the throttled gh() wrapper.
# Honours token hygiene: the caller passes which token context to probe.
#   _arl_probe <gh|ghsrc>
_arl_probe() {
  local who="${1:-gh}"
  local resp
  if [[ "$who" == "ghsrc" ]]; then
    resp="$(GH_TOKEN="${GH_TOKEN_SOURCE:-}" command gh api rate_limit 2>/dev/null)" || resp=""
  else
    resp="$(command gh api rate_limit 2>/dev/null)" || resp=""
  fi
  [[ -z "$resp" ]] && return 1
  # Extract core + graphql buckets. resources.core / resources.graphql each carry
  # {limit, used, remaining, reset}. (rate_limit itself does NOT consume quota.)
  local core_lim core_used core_reset gql_lim gql_used gql_reset
  core_lim="$(printf '%s' "$resp"  | jq -r '.resources.core.limit    // 0' 2>/dev/null || echo 0)"
  core_used="$(printf '%s' "$resp" | jq -r '.resources.core.used     // 0' 2>/dev/null || echo 0)"
  core_reset="$(printf '%s' "$resp"| jq -r '.resources.core.reset    // 0' 2>/dev/null || echo 0)"
  gql_lim="$(printf '%s' "$resp"   | jq -r '.resources.graphql.limit // 0' 2>/dev/null || echo 0)"
  gql_used="$(printf '%s' "$resp"  | jq -r '.resources.graphql.used  // 0' 2>/dev/null || echo 0)"
  gql_reset="$(printf '%s' "$resp" | jq -r '.resources.graphql.reset // 0' 2>/dev/null || echo 0)"
  # NOTE: _throttle_set takes the FILTER as $1, then jq args.
  _throttle_set \
    '.arl_core_limit=$cl | .arl_core_used=$cu | .arl_core_reset=$cr |
     .arl_gql_limit=$gl  | .arl_gql_used=$gu  | .arl_gql_reset=$gr  |
     .arl_probe_at=$now' \
    --argjson cl "$core_lim" --argjson cu "$core_used" --argjson cr "$core_reset" \
    --argjson gl "$gql_lim" --argjson gu "$gql_used" --argjson gr "$gql_reset" \
    --argjson now "$(date +%s)"

  # ---- Publish the probe result: console line + cached summary file ---------
  # core_pct / gql_pct = used/limit as integer percent (guard divide-by-zero).
  local core_pct=0 gql_pct=0 now_s
  now_s="$(date +%s)"
  (( core_lim > 0 )) && core_pct=$(( core_used * 100 / core_lim ))
  (( gql_lim  > 0 )) && gql_pct=$(( gql_used  * 100 / gql_lim  ))
  local core_in=0 gql_in=0
  (( core_reset > now_s )) && core_in=$(( core_reset - now_s ))
  (( gql_reset  > now_s )) && gql_in=$(( gql_reset  - now_s ))
  local rl_line
  rl_line="rate-limit [$who]: core ${core_used}/${core_lim} (${core_pct}%, reset in $(_hms "$core_in")), graphql ${gql_used}/${gql_lim} (${gql_pct}%, reset in $(_hms "$gql_in"))"
  log "$rl_line"
  # Cache to a file the human status (.progress) and operators can read/watch.
  printf '%s\nupdated: %s\n' "$rl_line" "$(now)" > "$(_ratelimit_summary_path)" 2>/dev/null || true
  return 0
}

# _ratelimit_summary_path — file holding the latest rate-limit probe summary,
# shown in console at probe time and embedded in state/.progress.
_ratelimit_summary_path() {
  echo "${REPO_ROOT:-.}/state/.rate-limit"
}

# _arl_gate <gh|ghsrc> — AUTORATELIMIT enforcement, called from _throttle_pre_write.
# No-op when AUTORATELIMIT=0. Otherwise: refresh the snapshot every N writes, then
# if any relevant bucket's used/limit >= AUTORATELIMIT, sleep until that bucket's
# reset (+buffer). Falls back to a bounded exponential sleep if reset is unknown.
_arl_gate() {
  local who="${1:-gh}"
  # AUTORATELIMIT is a float in (0,1]; "0" / empty disables.
  awk -v n="${AUTORATELIMIT:-0}" 'BEGIN{exit !(n+0>0)}' || return 0

  _throttle_init
  local now probe_at
  now="$(date +%s)"
  probe_at="$(_throttle_get arl_probe_at)"
  [[ "$probe_at" =~ ^[0-9]+$ ]] || probe_at=0

  # Refresh snapshot every AUTORATELIMIT_PROBE_EVERY writes (writes_total advances
  # in _throttle_post_write), OR if we have never probed.
  local wt
  wt="$(_throttle_get writes_total)"; [[ "$wt" =~ ^[0-9]+$ ]] || wt=0
  if (( probe_at == 0 )) || (( wt % AUTORATELIMIT_PROBE_EVERY == 0 )); then
    _arl_probe "$who" || true
  fi

  # Evaluate both core and graphql buckets; sleep for the WORST (latest) reset
  # among any bucket that is at/over the threshold.
  local lim used reset frac_num
  local need_sleep_until=0 over_desc=""
  local b
  for b in core gql; do
    lim="$(_throttle_get "arl_${b}_limit")";  [[ "$lim"  =~ ^[0-9]+$ ]] || lim=0
    used="$(_throttle_get "arl_${b}_used")";   [[ "$used" =~ ^[0-9]+$ ]] || used=0
    reset="$(_throttle_get "arl_${b}_reset")"; [[ "$reset" =~ ^[0-9]+$ ]] || reset=0
    (( lim <= 0 )) && continue
    # over-threshold?  used/lim >= AUTORATELIMIT   (float compare via awk)
    if awk -v u="$used" -v l="$lim" -v n="$AUTORATELIMIT" 'BEGIN{exit !((u/l) >= n)}'; then
      # Mark this bucket as over-threshold regardless of reset usability — this
      # drives BOTH the precise sleep-to-reset path (when reset is a usable future
      # epoch) AND the bounded-exponential fallback (when it is not).
      over_desc="$b ${used}/${lim}"
      if (( reset > now && reset > need_sleep_until )); then
        need_sleep_until="$reset"
      fi
    fi
  done

  if (( need_sleep_until > now )); then
    local wait=$(( need_sleep_until - now + AUTORATELIMIT_RESET_BUFFER ))
    warn "[autoratelimit] ${over_desc} ≥ ${AUTORATELIMIT} of limit — sleeping ${wait}s until reset"
    sleep "$wait"
    _throttle_set '.arl_fallback_step = 0'
    _arl_probe "$who" || true
    return 0
  fi

  # If we are over threshold but have NO usable reset epoch, use the bounded
  # exponential fallback (base^step, capped), escalating each consecutive hit.
  if [[ -n "$over_desc" ]]; then
    local step
    step="$(_throttle_get arl_fallback_step)"; [[ "$step" =~ ^[0-9]+$ ]] || step=0
    step=$(( step + 1 ))
    local wait=1 i
    for (( i=0; i<step; i++ )); do wait=$(( wait * AUTORATELIMIT_FALLBACK_BASE )); done
    (( wait > AUTORATELIMIT_FALLBACK_MAX )) && wait="$AUTORATELIMIT_FALLBACK_MAX"
    warn "[autoratelimit] ${over_desc} ≥ ${AUTORATELIMIT} of limit, reset unknown — fallback sleep ${wait}s (step $step)"
    sleep "$wait"
    _throttle_set '.arl_fallback_step = $s' --argjson s "$step"
  else
    # Under threshold — reset the fallback escalation.
    _throttle_set '.arl_fallback_step = 0'
  fi
}

# _throttle_get <key> — read one numeric/bool field from the state file.
_throttle_get() {
  jq -r ".$1" "$THROTTLE_STATE" 2>/dev/null || echo 0
}

# _throttle_set <jq-filter> [args...] — atomically update the state file.
_throttle_set() {
  local filter="$1"; shift
  local tmp
  tmp="$(mktemp)"
  if jq "$@" "$filter" "$THROTTLE_STATE" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$THROTTLE_STATE"
  else
    rm -f "$tmp"
  fi
}

# _throttle_enter_degraded — flip to degraded mode (slower, smaller batches).
_throttle_enter_degraded() {
  _throttle_init
  _throttle_set '.degraded = true'
  warn "[throttle] DEGRADED MODE engaged — write delay ${DEGRADED_WRITE_DELAY_SECONDS}s, batch pause every ${DEGRADED_BATCH_SIZE_WRITES} writes"
}

# _is_write_args — return 0 if the gh argv represents a mutating request.
# Recognizes:
#   - api ... --method POST|PATCH|PUT|DELETE
#   - gh release upload|delete|create|edit|delete-asset
#   - api graphql with a query/-f query value that begins with "mutation"
#     (GraphQL mutations carry no --method, so without this they would silently
#      bypass the write-throttle — see CLAUDE.md write-throttle rule #3).
# Everything else (api GET, api graphql QUERIES, release view, etc.) is a read.
_is_write_args() {
  local prev="" a
  local saw_graphql=0
  for a in "$@"; do
    if [[ "$prev" == "--method" ]]; then
      case "$a" in POST|PATCH|PUT|DELETE|post|patch|put|delete) return 0 ;; esac
    fi
    [[ "$a" == "graphql" ]] && saw_graphql=1
    # Detect a GraphQL mutation: a query argument whose (leading-whitespace-
    # stripped) text starts with the keyword "mutation". Matches both
    # 'query=mutation...' (from -f query=...) and a bare 'mutation ...' value.
    if [[ "$saw_graphql" -eq 1 ]]; then
      local v="$a"
      v="${v#query=}"                 # strip a leading "query=" if present
      v="${v#"${v%%[![:space:]]*}"}"  # strip leading whitespace
      [[ "$v" == mutation* ]] && return 0
    fi
    prev="$a"
  done
  # gh release upload / delete / create / edit are writes
  if [[ "${1:-}" == "release" ]]; then
    case "${2:-}" in upload|delete|create|edit|delete-asset) return 0 ;; esac
  fi
  return 1
}

# _throttle_pre_write — gate BEFORE a mutating call: enforce hourly cap and the
# low-remaining watermark. Called from the wrapper just before the real gh runs.
_throttle_pre_write() {
  _throttle_init

  # ---- AUTORATELIMIT: header-driven adaptive backoff (no-op when =0) -------
  # Writes hit the TARGET org's primary limit (the `gh` token context).
  _arl_gate gh

  # ---- Hourly cap: roll the window, sleep if the cap is hit ----------------
  local now win_start in_hour
  now="$(date +%s)"
  win_start="$(_throttle_get hour_window_start)"
  in_hour="$(_throttle_get writes_in_hour)"
  [[ -z "$win_start" || "$win_start" == "null" ]] && win_start="$now"
  [[ -z "$in_hour"  || "$in_hour"  == "null" ]] && in_hour=0

  local elapsed=$(( now - win_start ))
  if (( elapsed >= 3600 )); then
    # Window expired — reset. (filter FIRST, then jq args — see _throttle_set.)
    _throttle_set '.hour_window_start = $now | .writes_in_hour = 0' --argjson now "$now"
  elif (( in_hour >= MAX_WRITES_PER_HOUR )); then
    local wait=$(( 3600 - elapsed + 60 ))
    warn "[throttle] hourly write cap reached ($in_hour/$MAX_WRITES_PER_HOUR) — sleeping ${wait}s until window reset"
    sleep "$wait"
    now="$(date +%s)"
    _throttle_set '.hour_window_start = $now | .writes_in_hour = 0' --argjson now "$now"
  fi
}

# _throttle_post_write — called AFTER a successful mutating call. Increments the
# counters, applies the per-write delay, and the batch pause when due.
_throttle_post_write() {
  _throttle_init
  local degraded delay batch_size batch_pause in_batch
  degraded="$(_throttle_get degraded)"

  if [[ "$degraded" == "true" ]]; then
    delay="$DEGRADED_WRITE_DELAY_SECONDS"
    batch_size="$DEGRADED_BATCH_SIZE_WRITES"
    batch_pause="$DEGRADED_BATCH_PAUSE_SECONDS"
  else
    delay="$WRITE_DELAY_SECONDS"
    batch_size="$BATCH_SIZE_WRITES"
    batch_pause="$BATCH_PAUSE_SECONDS"
  fi

  _throttle_set '.writes_total += 1 | .writes_in_batch += 1 | .writes_in_hour += 1'

  in_batch="$(_throttle_get writes_in_batch)"

  # Rate-limit VISIBILITY probe (RATELIMIT_SHOW=1) when AUTORATELIMIT is OFF — the
  # gate already probes when AUTORATELIMIT>0, so only probe here to avoid a double.
  if [[ "${RATELIMIT_SHOW:-0}" == "1" ]] && \
     awk -v n="${AUTORATELIMIT:-0}" 'BEGIN{exit !(n+0==0)}'; then
    local _wt
    _wt="$(_throttle_get writes_total)"; [[ "$_wt" =~ ^[0-9]+$ ]] || _wt=0
    if (( _wt % AUTORATELIMIT_PROBE_EVERY == 0 )); then
      _arl_probe gh || true
    fi
  fi

  # Per-write delay (policy default 10s; 20s degraded).
  sleep "$delay"

  # Batch pause after every N successful writes.
  if (( in_batch >= batch_size )); then
    warn "[throttle] batch of $in_batch writes complete — pausing ${batch_pause}s (abuse-protection cooldown)"
    sleep "$batch_pause"
    _throttle_set '.writes_in_batch = 0'
  fi
}

# _throttle_on_rate_limit <retry_after_secs> — HARD STOP handler for 403/429.
# Sleeps the fallback duration, then engages degraded mode for the rest of the run.
_throttle_on_rate_limit() {
  local retry_after="${1:-}"
  local wait
  if [[ -n "$retry_after" && "$retry_after" =~ ^[0-9]+$ ]]; then
    wait=$(( retry_after + 60 ))
    err "[throttle] 403/429 rate limit — Retry-After=${retry_after}s; HARD STOP, sleeping $((wait))s before degraded resume"
  else
    wait="$RATE_LIMIT_FALLBACK_PAUSE_SECONDS"
    err "[throttle] 403/429 rate limit — no Retry-After; HARD STOP, sleeping ${wait}s before degraded resume"
  fi
  sleep "$wait"
  _throttle_enter_degraded
  _throttle_set '.writes_in_batch = 0'
}

# _looks_like_rate_limit <text> — heuristic match on a gh error body/stderr.
_looks_like_rate_limit() {
  echo "$1" | grep -qiE 'rate.?limit|secondary rate|abuse|too many requests|403|429' 2>/dev/null
}

# Remove a rewrite-crossrefs.yaml entry so stage 07 re-processes the body
# on its next run.  Call after any PATCH that replaces a mirrored issue/PR body.
_clear_crossref_record() {
  local repo_name="$1"
  local tgt_number="$2"
  local crossrefs_file="${REPO_ROOT}/state/rewrite-crossrefs.yaml"
  [[ -f "$crossrefs_file" ]] || return 0
  local tmp
  tmp="$(mktemp)"
  jq --arg r "$repo_name" --argjson n "$tgt_number" \
    '.items = [.items[] | select((.repo == $r and .target_number == $n) | not)]' \
    "$crossrefs_file" > "$tmp" && mv "$tmp" "$crossrefs_file" || rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# Run mode
# ---------------------------------------------------------------------------
# MIRROR_MODE controls the data-flow direction of every stage:
#
#   full   (default) — read SOURCE and write TARGET in a single pass
#                      (the original behaviour; needs all four creds).
#   export           — read SOURCE only, serialize everything into state/ files.
#                      NEVER touches the target org. Needs GH_TOKEN_SOURCE + SOURCE_ORG.
#   import           — read state/ files only, write to TARGET org.
#                      NEVER touches the source org. Needs GH_TOKEN + TARGET_ORG.
#
# The export/import split lets you snapshot the source on one machine and replay
# it onto the target on another, with the serialized data travelling in state/.
#
# Stage 02 is the sole exception: instead of serializing repo contents to JSON it
# uses local bare git clones (mirror-clones/) — see that stage for details.
MIRROR_MODE="${MIRROR_MODE:-full}"

case "$MIRROR_MODE" in
  full|export|import) ;;
  *)
    echo "FATAL: MIRROR_MODE must be one of: full | export | import (got '$MIRROR_MODE')" >&2
    exit 1
    ;;
esac

# Mode predicates — use these in stages for readable branching.
#   if in_export; then ... ; fi
in_full()   { [[ "$MIRROR_MODE" == "full"   ]]; }
in_export() { [[ "$MIRROR_MODE" == "export" ]]; }
in_import() { [[ "$MIRROR_MODE" == "import" ]]; }

# writes_target — true when the current mode may write to the target org
# (full or import). Stages gate all target mutations behind this.
writes_target() { [[ "$MIRROR_MODE" == "full" || "$MIRROR_MODE" == "import" ]]; }

# reads_source — true when the current mode may read the source org
# (full or export). Stages gate all source reads behind this.
reads_source()  { [[ "$MIRROR_MODE" == "full" || "$MIRROR_MODE" == "export" ]]; }

# ===========================================================================
# API-rate visibility — rolling 60-minute request counters
# ===========================================================================
# Separately from the write-throttle (which ENFORCES the cap), this records every
# gh invocation so we can SHOW how many requests went out in the last 60 minutes,
# broken down by category. Source and target have independent GitHub rate limits
# (different tokens/orgs), so they are counted separately:
#
#   source-read   — a read against the SOURCE org (ghsrc ...)
#   target-read   — a read against the TARGET org (gh, non-mutating)
#   target-write  — a mutating call against the TARGET org (gh, POST/PATCH/PUT/
#                   DELETE, release upload, or a GraphQL mutation)
#
# Fidelity note: a count is per `gh` INVOCATION, not per HTTP request. Writes are
# always a single HTTP request (never --paginate), so target-write is EXACT — and
# that is the abuse-sensitive number. Reads may use --paginate (N HTTP requests
# per invocation), so source-read/target-read are a LOWER BOUND on HTTP calls;
# this is called out in the report so the number is never misread.
#
# Implementation: an append-only log of "<epoch> <category>" lines. Counting a
# rolling window = select lines with epoch >= now-3600. The log is pruned to the
# window opportunistically so it stays small. File-based → subshell-safe (the
# wrappers run inside command-substitution subshells).

APIRATE_LOG="${APIRATE_LOG:-}"
# How often (in recorded events) to auto-print the rolling summary. 0 disables
# the periodic line (the end-of-stage summary still prints).
APIRATE_REPORT_EVERY="${APIRATE_REPORT_EVERY:-50}"

_apirate_log_path() {
  # Use :- so an unset (not just empty) APIRATE_LOG can't trip `set -u`.
  if [[ -z "${APIRATE_LOG:-}" ]]; then
    APIRATE_LOG="${REPO_ROOT:-.}/state/.api-rate.log"
  fi
  echo "$APIRATE_LOG"
}

# _apirate_summary_path — cache file holding the LAST computed API-rate summary
# line, so the human status file (.progress) can display it without recomputing.
_apirate_summary_path() {
  echo "${REPO_ROOT:-.}/state/.api-rate.summary"
}

# _apirate_record <category> — append one event and, every APIRATE_REPORT_EVERY
# events, emit the rolling-60m summary. Best-effort: never fails the caller.
_apirate_record() {
  local cat="$1"
  local lf; lf="$(_apirate_log_path)"
  mkdir -p "$(dirname "$lf")" 2>/dev/null || true
  local now; now="$(date +%s)"
  printf '%s %s\n' "$now" "$cat" >> "$lf" 2>/dev/null || return 0

  [[ "$APIRATE_REPORT_EVERY" -le 0 ]] && return 0
  # Cheap line-count gate; only do the (heavier) windowed count/prune when due.
  local n
  n="$(wc -l < "$lf" 2>/dev/null || echo 0)"
  n="${n//[[:space:]]/}"
  [[ -z "$n" ]] && return 0
  if (( n % APIRATE_REPORT_EVERY == 0 )); then
    apirate_report
  fi
}

# apirate_report — print counts of API calls in the last 60 minutes, by category,
# and prune the log to the window. Safe to call any time (e.g. end of a stage).
apirate_report() {
  local lf; lf="$(_apirate_log_path)"
  [[ -f "$lf" ]] || return 0
  local now cutoff
  now="$(date +%s)"
  cutoff=$(( now - 3600 ))

  # Single awk pass: count per category within the window, and rewrite the file
  # to only the in-window lines (prune). Totals are emitted on the COUNT line.
  local tmp; tmp="$(mktemp)"
  awk -v cutoff="$cutoff" -v out="$tmp" '
    # Only consider well-formed lines: a purely-numeric epoch in $1. This avoids
    # awk string-vs-number coercion counting a malformed line (total != category
    # sum), and drops any garbage during the prune.
    ($1 ~ /^[0-9]+$/) && ($1 + 0 >= cutoff) {
      print > out                       # keep (prune to window)
      c[$2]++; total++
    }
    END {
      printf "%d %d %d %d\n", \
        (c["source-read"]+0), (c["target-read"]+0), (c["target-write"]+0), (total+0)
    }
  ' "$lf" > "$tmp.counts" 2>/dev/null || { rm -f "$tmp" "$tmp.counts"; return 0; }
  mv "$tmp" "$lf" 2>/dev/null || rm -f "$tmp"

  local sr tr tw tot
  read -r sr tr tw tot < "$tmp.counts" 2>/dev/null || { rm -f "$tmp.counts"; return 0; }
  rm -f "$tmp.counts"
  : "${sr:=0}" "${tr:=0}" "${tw:=0}" "${tot:=0}"

  # Also surface the write cap so the number has context (the abuse-sensitive one).
  local cap="${MAX_WRITES_PER_HOUR:-350}"
  local rate_line="API rate (last 60m): ${tot} calls — source-read ${sr}, target-read ${tr}, target-write ${tw}/${cap} cap (reads count invocations; --paginate may be >1 HTTP each)"
  log "$rate_line"
  # Cache the summary so the human status file (.progress) can show it inline.
  printf '%s\n' "$rate_line" > "$(_apirate_summary_path)" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# GitHub API helpers
# ---------------------------------------------------------------------------
# gh — wrapper around the real gh binary that enforces token-hygiene per mode
# AND applies the write-throttle policy to every mutating request.
#
# In export mode a direct `gh` call (target API) is a bug: the export pass must
# not touch the target org. We hard-fail so violations surface immediately in CI
# instead of silently mutating the target. ghsrc bypasses this via `command gh`.
#
# Throttling (writes only — reads pass straight through):
#   1. _throttle_pre_write: enforce the hourly cap / low-remaining watermark.
#   2. Run the real gh, preserving the caller's stdout + exit code VERBATIM
#      (callers depend on capturing stdout via $(...) and on the exit status;
#      we must not alter either). stderr is duplicated to a temp file so we can
#      classify rate-limit failures without disturbing the caller's own 2> redirect.
#   3. On success: _throttle_post_write (counter + per-write delay + batch pause).
#      On failure that looks like 403/429: _throttle_on_rate_limit (HARD STOP →
#      fallback sleep → degraded mode), then return the original non-zero exit so
#      the caller's existing FAILED handling still records the item.
gh() {
  if [[ "$MIRROR_MODE" == "export" ]]; then
    err "gh (target API) called in export mode — forbidden. Use ghsrc for source reads."
    err "  args: $*"
    exit 1
  fi

  # Reads: no throttle, straight through (preserves stdout/stderr/exit exactly).
  if ! _is_write_args "$@"; then
    _apirate_record "target-read"
    command gh "$@"
    return $?
  fi

  # ---- Mutating request: apply the throttle policy -------------------------
  _throttle_pre_write

  # Run the real gh. We must hand the caller back stdout + exit code unchanged.
  # stderr is captured to a temp file (synchronously) for rate-limit
  # classification, then replayed to fd 2 — so a caller's `2>/dev/null` or
  # `2>"$f"` still behaves exactly as written (fd 2 here is whatever the caller
  # redirected the gh() call's stderr to). stdout (fd 1) is never touched, so
  # `result="$(gh api ...)"` captures the body verbatim.
  local _gh_err _rc
  _gh_err="$(mktemp)"
  command gh "$@" 2>"$_gh_err"; _rc=$?
  cat "$_gh_err" >&2 2>/dev/null || true

  if [[ "$_rc" -eq 0 ]]; then
    rm -f "$_gh_err"
    _apirate_record "target-write"
    _throttle_post_write
    return 0
  fi

  # Failure — classify. Read the captured stderr (and probe is cheap).
  local _err_text
  _err_text="$(cat "$_gh_err" 2>/dev/null || true)"
  rm -f "$_gh_err"
  if _looks_like_rate_limit "$_err_text"; then
    # Extract Retry-After if gh surfaced it; otherwise fallback pause.
    local _ra
    _ra="$(echo "$_err_text" | grep -ioE 'retry-after[: ]+[0-9]+' | grep -oE '[0-9]+' | head -1 || true)"
    _throttle_on_rate_limit "$_ra"
  fi
  # Return the ORIGINAL non-zero exit so callers' FAILED handling is unchanged.
  return "$_rc"
}

# ghsrc — call GitHub API authenticated as the SOURCE org token.
# Bypasses the gh() wrapper (calls `command gh` directly) because its own guard
# below is authoritative for source access. In import mode a source read is a
# bug: the import pass replays serialized state and must not touch the source.
ghsrc() {
  if [[ "$MIRROR_MODE" == "import" ]]; then
    err "ghsrc (source API) called in import mode — forbidden. Import replays state/ only."
    err "  args: $*"
    exit 1
  fi
  _apirate_record "source-read"
  GH_TOKEN="${GH_TOKEN_SOURCE}" command gh "$@"
}

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
preflight() {
  local missing=0

  for cmd in gh git jq; do
    if ! command -v "$cmd" &>/dev/null; then
      err "Required command not found: $cmd"
      missing=1
    fi
  done

  # Credential requirements depend on MIRROR_MODE. Each mode requires ONLY the
  # creds for the org it actually contacts, so an export run on a locked-down
  # machine never needs the target token, and vice versa.
  if reads_source; then
    if [[ -z "${GH_TOKEN_SOURCE:-}" ]]; then
      err "GH_TOKEN_SOURCE is not set (source org token; required in $MIRROR_MODE mode)"
      missing=1
    fi
    if [[ -z "${SOURCE_ORG:-}" ]]; then
      err "SOURCE_ORG is not set (required in $MIRROR_MODE mode)"
      missing=1
    fi
  fi

  if writes_target; then
    if [[ -z "${GH_TOKEN:-}" ]]; then
      err "GH_TOKEN is not set (target org token; required in $MIRROR_MODE mode)"
      missing=1
    fi
    if [[ -z "${TARGET_ORG:-}" ]]; then
      err "TARGET_ORG is not set (required in $MIRROR_MODE mode)"
      missing=1
    fi
  fi

  if [[ "$missing" -ne 0 ]]; then
    err "Preflight checks failed. Exiting."
    exit 1
  fi

  config_load
  ok "Preflight passed (mode=$MIRROR_MODE${SOURCE_ORG:+, SOURCE_ORG=$SOURCE_ORG}${TARGET_ORG:+, TARGET_ORG=$TARGET_ORG})"
}

# ---------------------------------------------------------------------------
# State file helpers
# ---------------------------------------------------------------------------

# state_read — read a state file, return '{}' if missing
state_read() {
  local file="$1"
  if [[ -f "$file" ]]; then
    cat "$file"
  else
    echo '{}'
  fi
}

# state_init — create state file with meta envelope if it doesn't exist
# Usage: state_init <file> <stage-name>
state_init() {
  local file="$1"
  local stage="$2"
  local ts
  ts="$(now)"

  if [[ -f "$file" ]]; then
    # File exists — just update last_run_at
    local tmp
    tmp="$(mktemp)"
    jq --arg ts "$ts" '.meta.last_run_at = $ts' "$file" > "$tmp"
    mv "$tmp" "$file"
    return 0
  fi

  # Create parent directory if needed
  mkdir -p "$(dirname "$file")"

  # target_org is recorded ONLY when this mode actually writes to a target
  # (full or import). In export mode the target is unknown and irrelevant — the
  # snapshot is chosen for a target at IMPORT time — so we record null instead of
  # the hardcoded TARGET_ORG fallback, which would otherwise bake a misleading
  # (and possibly wrong) target org into a pure source snapshot.
  # Use :- so a source-only stage that never declares TARGET_ORG (e.g. the
  # projects export) does not trip `set -u` here.
  local tgt_value="${TARGET_ORG:-}"
  if in_export; then
    tgt_value=""
  fi

  jq -n \
    --arg stage   "$stage" \
    --arg src     "${SOURCE_ORG}" \
    --arg tgt     "$tgt_value" \
    --arg ts      "$ts" \
    '{
      meta: {
        stage:        $stage,
        source_org:   $src,
        target_org:   (if $tgt == "" then null else $tgt end),
        first_run_at: $ts,
        last_run_at:  $ts
      },
      items: [],
      stats: { total: 0, synced: 0, pending: 0, failed: 0 }
    }' > "$file"
}

# state_update — apply a jq filter to a state file atomically
# Usage: state_update <file> <jq-filter> [jq-args...]
state_update() {
  local file="$1"
  local filter="$2"
  shift 2

  local tmp
  tmp="$(mktemp)"

  # Pass remaining args as extra jq args
  jq "$@" "$filter" "$file" > "$tmp"
  mv "$tmp" "$file"
}

# state_items — emit each item in a state file as one compact JSON line.
# Used by every import loop to iterate serialized source data uniformly:
#   while IFS= read -r item; do ... ; done < <(state_items "$state_file")
state_items() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  jq -c '.items[]?' "$file" 2>/dev/null || true
}

# ===========================================================================
# Large state-file splitting (GitHub 100 MB hard limit / 50 MB warning)
# ===========================================================================
# Some repos produce huge issue/PR state files (a busy repo's PR file with all
# review diffs can be hundreds of MB). GitHub refuses files >100 MB, so we split
# any oversized state file into parts that travel through git, then reassemble
# them before any code reads the file.
#
# CONTRACT — merge-before-read, split-before-commit:
#   * The canonical working file is always the WHOLE  <repo>.yaml.  All stage
#     logic (05/06 import, 07 crossrefs, 08 assign, validation) operates on it.
#   * Parts are named  <repo>.yaml.partNN  (NN = 01,02,...). They DELIBERATELY do
#     not end in `.yaml`, so every existing  *.yaml  glob still sees exactly one
#     file per repo and never mistakes a part for a separate repo.
#   * When parts exist but the whole file does not (e.g. freshly pulled on the
#     import machine), state_unsplit reassembles them first.
#   * A manifest  <repo>.yaml.parts  records the part count + ordering so
#     reassembly is unambiguous.
#
# Split strategy is size-aware bin-packing over .items[] (NOT "N items per file"),
# because a single item can be large. The meta/stats envelope is replicated into
# every part so each part is itself valid JSON and self-describing; on reassembly
# the envelope is taken from part 01 and all items[] are concatenated in order.

# Per-part size budget in MB. 10 MB keeps parts far under GitHub's limits and
# leaves headroom for the replicated envelope. Override via env if needed.
MAX_STATE_FILE_MB="${MAX_STATE_FILE_MB:-10}"

# _state_part_files <whole_file> — print this file's part paths, one per line, in
# correct NUMERIC order (part2 before part10). Matches any digit width (part1,
# part01, part0001, part100, ...) so we never silently drop parts beyond 99 (the
# old fixed [0-9][0-9] glob did exactly that, causing data loss for >99-part files).
# Robust to repo names containing dots: we only look at the trailing ".partNNN".
_state_part_files() {
  local whole="$1"
  local base
  base="$(basename "$whole")"
  local dir
  dir="$(dirname "$whole")"
  [[ -d "$dir" ]] || return 0
  # List candidates, keep only "<base>.part<digits>", sort numerically by <digits>.
  local f name num
  for f in "$dir"/"$base".part*; do
    [[ -e "$f" ]] || continue
    name="$(basename "$f")"
    num="${name##*.part}"
    [[ "$num" =~ ^[0-9]+$ ]] || continue
    printf '%020d\t%s\n' "$((10#$num))" "$f"
  done | sort | cut -f2-
}

# state_repo_names <dir> — list distinct repo base names in <dir>, discovering
# them from BOTH whole files (<repo>.yaml) and split manifests (<repo>.yaml.parts).
# This lets enumerators find repos that exist only as parts (e.g. freshly pulled
# on the import machine before reassembly). Prints one repo name per line, sorted.
state_repo_names() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0
  {
    shopt -s nullglob
    local f
    for f in "$dir"/*.yaml;       do [[ -e "$f" ]] && basename "$f" .yaml; done
    for f in "$dir"/*.yaml.parts; do [[ -e "$f" ]] && basename "$f" .yaml.parts; done
    shopt -u nullglob
  } | sort -u
}

# _file_size_bytes <file> — portable file size in bytes (Linux + macOS).
_file_size_bytes() {
  local f="$1"
  [[ -f "$f" ]] || { echo 0; return; }
  stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null || echo 0
}

# state_unsplit <whole_file> — if part files exist for <whole_file>, reassemble
# them into the whole file (overwriting / creating it) and remove the parts +
# manifest. No-op if there are no parts. Safe to call before every read/write.
state_unsplit() {
  local whole="$1"
  local manifest="${whole}.parts"
  # Collect parts in correct numeric order (handles any digit width).
  local parts=()
  local p
  while IFS= read -r p; do [[ -n "$p" ]] && parts+=( "$p" ); done < <(_state_part_files "$whole")
  # Nothing to do if there are no parts.
  [[ ${#parts[@]} -eq 0 ]] && return 0

  # Defensive: if a manifest records a part count, verify it matches what we found
  # so a truncated/partial part set (e.g. an interrupted git checkout) is caught
  # rather than silently reassembled with missing items.
  if [[ -f "$manifest" ]]; then
    local expected
    expected="$(jq -r '.parts // empty' "$manifest" 2>/dev/null || true)"
    if [[ -n "$expected" && "$expected" =~ ^[0-9]+$ && "$expected" -ne "${#parts[@]}" ]]; then
      err "  [split] $(basename "$whole"): manifest expects $expected part(s) but found ${#parts[@]} — refusing to reassemble (incomplete part set)"
      return 1
    fi
  fi

  log "  [split] Reassembling ${#parts[@]} part(s) → $(basename "$whole")"
  local tmp
  tmp="$(mktemp)"
  # Envelope (meta+stats) from part 01; items[] = concatenation of every part's items.
  # Use --slurp so all parts are read as an array of envelopes.
  if jq -s '
        (.[0] | {meta, stats}) as $env
        | $env + { items: (map(.items[]?)) }
      ' "${parts[@]}" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$whole"
    # Dry-run must NOT mutate the on-disk split layout: produce the whole file so
    # readers work, but KEEP the parts + manifest. A real run consumes them.
    # (RC-23: a dry-run / test that reassembled parts permanently merged the
    #  operator's split state.)
    if [[ "${DRY_RUN:-0}" -eq 0 ]]; then
      rm -f "${parts[@]}" "$manifest"
    fi
  else
    rm -f "$tmp"
    err "  [split] Failed to reassemble parts for $(basename "$whole") — leaving parts in place"
    return 1
  fi
}

# state_split_if_needed <whole_file> — if <whole_file> exceeds the size budget,
# split it into <whole_file>.partNN files (size-aware bin-packing over items[])
# and REMOVE the whole file, leaving only parts + a .parts manifest for git.
# If it is within budget, ensure no stale parts/manifest linger. No-op if absent.
state_split_if_needed() {
  local whole="$1"
  [[ -f "$whole" ]] || return 0
  local manifest="${whole}.parts"
  local budget=$(( MAX_STATE_FILE_MB * 1024 * 1024 ))
  local size
  size="$(_file_size_bytes "$whole")"

  if (( size <= budget )); then
    # Within budget: clean up any leftover parts from a previous larger run.
    local stale=()
    local p
    while IFS= read -r p; do [[ -n "$p" ]] && stale+=( "$p" ); done < <(_state_part_files "$whole")
    [[ ${#stale[@]} -gt 0 ]] && rm -f "${stale[@]}" "$manifest"
    return 0
  fi

  log "  [split] $(basename "$whole") is $(( size / 1024 / 1024 ))MB > ${MAX_STATE_FILE_MB}MB — splitting into parts"

  # Emit the envelope once, and each item with its serialized byte length, so the
  # packer can bin-pack without re-measuring. Envelope is reused in every part.
  local env_tmp items_tmp
  env_tmp="$(mktemp)"; items_tmp="$(mktemp)"
  jq -c '{meta, stats}' "$whole" > "$env_tmp" 2>/dev/null
  # Each line: <bytelen>\t<compact-item-json>. The byte length drives bin-packing.
  jq -cr '.items[]? | "\(. | @json | length)\t\(. | @json)"' "$whole" > "$items_tmp" 2>/dev/null || true

  local part_idx=1
  local cur_bytes=0
  local env_bytes
  env_bytes="$(_file_size_bytes "$env_tmp")"
  local part_items_tmp
  part_items_tmp="$(mktemp)"
  : > "$part_items_tmp"

  # Effective per-part budget: reserve the envelope size plus a 10% safety margin
  # for JSON structural overhead (the "items":[...] wrapper, commas, the fact that
  # compact item lengths are measured individually but concatenated with separators).
  # This guarantees each emitted part stays comfortably under MAX_STATE_FILE_MB.
  local eff_budget=$(( budget - env_bytes - budget / 10 ))
  (( eff_budget < 1 )) && eff_budget=$(( budget / 2 ))

  _flush_part() {
    local idx_padded
    idx_padded="$(printf '%02d' "$part_idx")"
    local part_file="${whole}.part${idx_padded}"
    # Build a valid JSON file: envelope + this part's items[].
    # IMPORTANT: emit COMPACT JSON (-c). Pretty-printing would inflate the file
    # 20-30% beyond the compact item lengths the packer budgeted for, pushing
    # parts over MAX_STATE_FILE_MB. Compact output keeps file size ≈ sum(len).
    # part_items_tmp holds one compact item JSON per line; slurp into an array.
    jq -c -n --slurpfile env "$env_tmp" --slurpfile items "$part_items_tmp" \
      '$env[0] + { items: $items }' > "$part_file"
    : > "$part_items_tmp"
    cur_bytes=0
    part_idx=$(( part_idx + 1 ))
  }

  local len json
  while IFS=$'\t' read -r len json; do
    [[ -z "$len" ]] && continue
    # Warn if a single item alone is too big for the budget or for GitHub.
    if (( len > budget )); then
      warn "  [split] a single item in $(basename "$whole") is $(( len / 1024 / 1024 ))MB (> ${MAX_STATE_FILE_MB}MB budget) — it will occupy its own part"
      (( len > 100 * 1024 * 1024 )) && \
        err "  [split] that item is >100MB and GitHub will REJECT its part — manual intervention required"
    fi
    # If adding this item would overflow the effective budget and the current
    # part already has content, flush first.
    if (( cur_bytes > 0 && cur_bytes + len > eff_budget )); then
      _flush_part
    fi
    printf '%s\n' "$json" >> "$part_items_tmp"
    cur_bytes=$(( cur_bytes + len ))
  done < "$items_tmp"

  # Flush the final part if it has any items.
  if [[ -s "$part_items_tmp" ]]; then
    _flush_part
  fi

  local total_parts=$(( part_idx - 1 ))
  # Write the manifest and remove the whole file (parts replace it for git).
  jq -n --argjson n "$total_parts" --arg base "$(basename "$whole")" \
    '{base:$base, parts:$n, max_part_mb:'"$MAX_STATE_FILE_MB"'}' > "$manifest"
  rm -f "$whole" "$env_tmp" "$items_tmp" "$part_items_tmp"
  ok "  [split] $(basename "$whole") → $total_parts part(s)"
}

# state_update_stats — recompute stats from items array
# Expects items to have a "status" field
state_update_stats() {
  local file="$1"
  local tmp
  tmp="$(mktemp)"
  jq '
    .stats.total   = (.items | length) |
    .stats.synced  = (.items | map(select(.status == "synced" or .status == "mirrored" or .status == "invited" or .status == "accepted" or .status == "applied")) | length) |
    .stats.pending = (.items | map(select(.status == "pending")) | length) |
    .stats.failed  = (.items | map(select(.status == "failed")) | length)
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

# ---------------------------------------------------------------------------
# Git commit helper
# ---------------------------------------------------------------------------
# commit_state — stage state/ and validation-reports/, commit, push
# Usage: commit_state "commit message"
commit_state() {
  local msg="${1:-"mirror: update state [skip ci]"}"

  # Ensure we're in the repo root
  local repo_root
  repo_root="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -z "$repo_root" ]]; then
    warn "commit_state: could not find git root, skipping commit"
    return 0
  fi

  cd "$repo_root"

  git add mirror/state/ state/ validation-reports/ 2>/dev/null || true

  if git diff --cached --quiet; then
    log "commit_state: nothing to commit"
    return 0
  fi

  git -c user.name="github-actions[bot]" \
      -c user.email="github-actions[bot]@users.noreply.github.com" \
      commit --allow-empty -m "$msg"

  git push
  ok "commit_state: pushed — $msg"
}

# ---------------------------------------------------------------------------
# Dry-run helper
# ---------------------------------------------------------------------------
DRY_RUN=0

# ---------------------------------------------------------------------------
# Config helpers
# ---------------------------------------------------------------------------
# Populated by config_load (called from preflight).
MIRROR_CONFIG=""

# INVITE_MEMBERS — global mode flag derived from config.json invite_members.
#   1 = active migration / DR: invite members, apply assignees, sync team members
#   0 = backup / read-only mirror: skip all of the above
#
# Default 1 so scripts work even if config is partially written.
# RC-4: do NOT use "// true" — jq treats false as falsy and would discard it.
# Use explicit "== false" comparison instead.
INVITE_MEMBERS=1

# config_load — locate and validate mirror/config.json.
# Sets MIRROR_CONFIG and all global config-derived flags.
# Called automatically from preflight().
config_load() {
  local config_path="${REPO_ROOT}/mirror/config.json"
  if [[ ! -f "$config_path" ]]; then
    err "Mirror config not found: $config_path"
    exit 1
  fi
  if ! jq empty "$config_path" 2>/dev/null; then
    err "Mirror config is not valid JSON: $config_path"
    exit 1
  fi
  MIRROR_CONFIG="$config_path"

  # invite_members: explicit false → 0; anything else (true, missing) → 1.
  # RC-4: .invite_members == false is the only safe pattern for boolean presence.
  INVITE_MEMBERS="$(jq -r 'if (.invite_members == false) then "0" else "1" end' \
    "$config_path" 2>/dev/null || echo "1")"

  local invite_label
  invite_label="$([ "$INVITE_MEMBERS" -eq 1 ] && echo "true (active migration / DR mode)" || echo "false (backup / read-only mirror mode)")"
  log "Config loaded: $MIRROR_CONFIG"
  log "  invite_members = $invite_label"
}

check_dry_run() {
  for arg in "$@"; do
    if [[ "$arg" == "--dry-run" ]]; then
      DRY_RUN=1
      warn "DRY RUN mode — no API writes will be performed"
      return 0
    fi
  done
}

dry_run_skip() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] would execute: $*"
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# gh_flatten_wrapper <ghsrc|gh> <endpoint> <inner_key>
# Flatten a paginated endpoint that returns a WRAPPER OBJECT per page, e.g.
# Actions/Dependabot secrets+variables: each --paginate page is
#   {"total_count":N, "<inner_key>":[...]}.  Prints a JSON array of the inner items.
#
# C2 FIX (RC-8 for wrapper-object endpoints): the naive
#   jq -rs '[.[] | select(has("<key>")) | .<key>[]]'
# silently DROPS any page that is an error object (e.g. a transient 502
# {"message":"Server Error"}) because has("<key>") is false — truncating the
# inventory with no signal. Here we explicitly detect error/unexpected pages
# (an object lacking <inner_key>) and emit a WARNING, so silent truncation
# becomes a visible, actionable event. Output items are unchanged on the happy path.
gh_flatten_wrapper() {
  local cmd="$1" endpoint="$2" key="$3"
  local raw
  if [[ "$cmd" == "ghsrc" ]]; then
    raw="$(ghsrc api "${endpoint}?per_page=100" --paginate 2>/dev/null)" || raw=""
  else
    raw="$(gh api "${endpoint}?per_page=100" --paginate 2>/dev/null)" || raw=""
  fi
  if [[ -z "$raw" ]]; then
    warn "  [paginate] no/failed response from ${endpoint} — treating as empty (inventory may be incomplete)"
    echo '[]'
    return 0
  fi
  # Count pages that are objects but DON'T carry the expected key (error/garbage).
  local bad
  bad="$(printf '%s' "$raw" | jq -rs --arg k "$key" \
    '[.[] | select(type=="object") | select(has($k) | not)] | length' 2>/dev/null || echo 0)"
  if [[ "${bad:-0}" =~ ^[0-9]+$ ]] && (( bad > 0 )); then
    local firstmsg
    firstmsg="$(printf '%s' "$raw" | jq -rs --arg k "$key" \
      '[.[] | select(type=="object") | select(has($k) | not) | .message // "unexpected page"][0] // "unexpected page"' 2>/dev/null || true)"
    warn "  [paginate] ${endpoint}: ${bad} page(s) lacked '${key}' (e.g. \"${firstmsg}\") — inventory may be INCOMPLETE (transient error or scope?)"
  fi
  printf '%s' "$raw" | jq -rs --arg k "$key" \
    '[.[] | select(type=="object") | select(has($k)) | .[$k][] | select(type=="object")]' \
    2>/dev/null || echo '[]'
}

# ---------------------------------------------------------------------------
# Pagination helper — fetch all pages from a GitHub API endpoint
# ---------------------------------------------------------------------------
# gh_paginate <ghsrc|gh> <endpoint> [extra jq filter]
# Prints a JSON array of all items combined
gh_paginate() {
  local cmd="$1"   # "gh" or "ghsrc"
  local endpoint="$2"
  local filter="${3:-.}"

  local page=1
  local per_page=100
  local all="[]"

  while true; do
    local url="${endpoint}?per_page=${per_page}&page=${page}"
    local batch

    if [[ "$cmd" == "ghsrc" ]]; then
      batch="$(ghsrc api "$url" 2>/dev/null)" || batch='[]'
    else
      batch="$(gh api "$url" 2>/dev/null)" || batch='[]'
    fi

    # Normalize: extract first JSON value to guard against extra runner output (RC-3)
    batch="$(echo "$batch" | jq -rs '.[0] // []' 2>/dev/null)" || batch='[]'

    # If empty array or null, stop
    local count
    count="$(echo "$batch" | jq 'if type=="array" then length else 0 end' 2>/dev/null || echo 0)"
    if [[ "$count" -eq 0 ]]; then
      break
    fi

    all="$(echo "$all $batch" | jq -s 'add | map('"$filter"')')"
    page=$((page + 1))
  done

  echo "$all"
}
