#!/usr/bin/env bash
#
# watch-progress.sh - live view of a running migration / test / verification.
# Run it in a second terminal (or over ssh) while 02, 03 or 04 is running.
# Read-only: it only reads output/STATUS.txt and the log files, it contacts no server.
#
# Shows: overall progress (n/N repositories, OK / skipped / failed, elapsed, ETA),
#        the repository being copied and its current step, the live git or Git LFS
#        transfer (objects, files, bytes) and the last finished repositories.
#
# Usage: scripts/watch-progress.sh [-n SECONDS] [--once] [--follow] [--env FILE]
#   -n SECONDS   refresh interval (default 2)
#   --once       print the status once and exit
#   --follow     keep watching after the run has ended (waits for the next run)

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

INTERVAL=2; ONCE=false; FOLLOW=false
usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
while [ $# -gt 0 ]; do
  case "$1" in
    -n) INTERVAL="$2"; shift ;;
    --once) ONCE=true ;;
    --follow) FOLLOW=true ;;
    --env) ENV_FILE="$2"; shift ;;
    -h | --help) usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
  shift
done
[[ "$INTERVAL" =~ ^[0-9]+$ ]] && [ "$INTERVAL" -gt 0 ] || die "-n needs a number of seconds"

init_paths

field() { sed -n "s/^$1 *: //p" "$STATUS_FILE" 2>/dev/null | head -n 1; }

# last progress meter written by git (fetch/push) in the repository log
git_progress() {
  [ -f "$1" ] || return 0
  tail -c 20000 "$1" | tr '\r' '\n' |
    grep -E '(Enumerating|Counting|Compressing|Receiving|Resolving|Writing) objects:|(Downloading|Uploading) LFS objects:' |
    tail -n 1 | sed 's/^remote: //'
}

# last line of GIT_LFS_PROGRESS: "<direction> <n>/<files> <bytes>/<total bytes> <name>"
lfs_progress() {
  [ -s "$1" ] || return 0
  tail -n 1 "$1" | awk '
    function h(b,  u, i) { split("B KB MB GB TB", u, " "); i = 1; while (b >= 1024 && i < 5) { b /= 1024; i++ }
                           return sprintf(i == 1 ? "%d %s" : "%.1f %s", b, u[i]) }
    NF >= 3 { split($2, f, "/"); split($3, b, "/")
              printf "LFS %s: file %s of %s, %s / %s", $1, f[1], f[2], h(b[1]), h(b[2]) }'
}

render() {
  local state log lfsp report g l
  if [ ! -f "$STATUS_FILE" ]; then
    echo "No run yet: $STATUS_FILE does not exist."
    echo "Start scripts/02-test-single-repo.sh, 03-migrate-project.sh or 04-verify-project.sh."
    return
  fi
  cat "$STATUS_FILE"
  state="$(field state)"; log="$(field 'repo log')"; lfsp="$(field 'lfs progress')"; report="$(field report)"
  if [ "$state" = RUNNING ]; then
    g=""; l=""
    case "$(field 'current step')" in
      *"(git)"*) g="$(git_progress "$log")" ;;
      *LFS*) l="$(lfs_progress "$lfsp")" ;;
    esac
    echo
    echo "live transfer:"
    [ -n "$g" ] && echo "  git : $g"
    [ -n "$l" ] && echo "  lfs : $l"
    [ -z "$g$l" ] && echo "  (waiting for data)"
  fi
  if [ -n "$report" ] && [ -f "$report" ] && [ "$(wc -l <"$report")" -gt 1 ]; then
    echo
    echo "last finished repositories:"
    tail -n +2 "$report" | tail -n 8 | awk -F, '{ gsub(/"/, ""); printf "  %-20s %s\n", $3, $1 }'
  fi
}

while :; do
  out="$(render)"
  if [ -t 1 ] && [ "$ONCE" = false ]; then printf '\033[H\033[2J'; fi
  printf '%s\n' "$out"
  [ "$ONCE" = true ] && break
  state="$(field state)"
  if [ -f "$STATUS_FILE" ] && [ "$state" != RUNNING ] && [ "$FOLLOW" = false ]; then
    echo; echo "The run is over ($state). Use --follow to keep watching for the next run."
    break
  fi
  [ -t 1 ] && printf '\n(refresh every %ss - Ctrl-C to quit)\n' "$INTERVAL"
  sleep "$INTERVAL"
done
