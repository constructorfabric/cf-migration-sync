#!/usr/bin/env bash
# mirror/tools/split-state-files.sh
# Manually split oversized state files into GitHub-committable parts, or merge
# parts back into whole files. Uses the SAME engine as the stages (state_split_if_needed
# / state_unsplit in mirror/lib/common.sh), so the format is identical and the
# stages will transparently reassemble whatever this tool produces.
#
# A state file that exceeds MAX_STATE_FILE_MB (default 10 MB) is split into:
#   <repo>.yaml.part01, <repo>.yaml.part02, ...   (each valid JSON, < limit)
#   <repo>.yaml.parts                              (manifest: part count)
# and the original <repo>.yaml is removed. Parts deliberately do NOT end in
# `.yaml`, so every `*.yaml` glob in the pipeline still sees one file per repo.
#
# Usage:
#   # Split every oversized file under state/issues and state/prs (the common case):
#   ./mirror/tools/split-state-files.sh split
#
#   # Split a specific file (or files):
#   ./mirror/tools/split-state-files.sh split state/prs/cyberware-rust.yaml
#
#   # Merge parts back into whole files (e.g. to inspect locally):
#   ./mirror/tools/split-state-files.sh merge                       # all repos
#   ./mirror/tools/split-state-files.sh merge state/prs/cyber-insight.yaml
#
#   # Just report which files are over the limit:
#   ./mirror/tools/split-state-files.sh status
#
# Env:
#   MAX_STATE_FILE_MB   per-part size budget in MB (default 10)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# MIRROR_MODE is irrelevant here but common.sh validates it; default to full.
export MIRROR_MODE="${MIRROR_MODE:-full}"
source "$SCRIPT_DIR/../lib/common.sh"

# Default set of directories that hold large per-repo state files.
DEFAULT_DIRS=( "$REPO_ROOT/state/issues" "$REPO_ROOT/state/prs" )

_usage() {
  grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

# Collect target whole-file paths: explicit args, or every <repo>.yaml (+ split
# manifests) under the default dirs.
_collect_targets() {
  if [[ $# -gt 0 ]]; then
    printf '%s\n' "$@"
    return
  fi
  local d r
  for d in "${DEFAULT_DIRS[@]}"; do
    [[ -d "$d" ]] || continue
    while IFS= read -r r; do
      [[ -n "$r" ]] && echo "$d/$r.yaml"
    done < <(state_repo_names "$d")
  done
}

cmd="${1:-}"; shift || true

case "$cmd" in
  split)
    targets=()
    while IFS= read -r t; do targets+=("$t"); done < <(_collect_targets "$@")
    [[ ${#targets[@]} -eq 0 ]] && { echo "No state files found."; exit 0; }
    for f in "${targets[@]}"; do
      # Reassemble any existing parts first so re-splitting is idempotent.
      state_unsplit "$f"
      state_split_if_needed "$f"
    done
    echo "Done. Split any file larger than ${MAX_STATE_FILE_MB}MB."
    ;;

  merge)
    targets=()
    while IFS= read -r t; do targets+=("$t"); done < <(_collect_targets "$@")
    [[ ${#targets[@]} -eq 0 ]] && { echo "No state files found."; exit 0; }
    for f in "${targets[@]}"; do
      state_unsplit "$f"
    done
    echo "Done. Reassembled all parts into whole .yaml files."
    ;;

  status)
    budget=$(( MAX_STATE_FILE_MB * 1024 * 1024 ))
    printf '%-50s %10s %s\n' "FILE" "SIZE" "STATE"
    while IFS= read -r f; do
      base="$(basename "$f")"
      if [[ -f "$f" ]]; then
        sz="$(_file_size_bytes "$f")"
        flag=""
        (( sz > budget )) && flag="  ⚠ OVER ${MAX_STATE_FILE_MB}MB — needs split"
        printf '%-50s %9dMB whole%s\n' "$base" "$(( sz / 1024 / 1024 ))" "$flag"
      elif [[ -f "${f}.parts" ]]; then
        n="$(jq -r '.parts' "${f}.parts" 2>/dev/null || echo '?')"
        printf '%-50s %10s split into %s part(s)\n' "$base" "-" "$n"
      fi
    done < <(_collect_targets "$@")
    ;;

  ""|-h|--help|help)
    _usage 0
    ;;

  *)
    echo "Unknown command: $cmd" >&2
    _usage 1
    ;;
esac
