#!/usr/bin/env bash
# Migrates all repositories of the project (branches, tags, Git LFS files, default branch).
# Run it again after an error or an interruption: migrated repositories are skipped.
# Usage: scripts/03-migrate-project.sh [--sync] [repo-slug ...]
#   --sync     also update the repositories already migrated with what changed on the source
#   repo-slug  migrate only these repositories
# PARALLEL in .env = number of repositories copied at the same time (default 1).
# Follow it live from another terminal: scripts/status.sh -w   (or tail -f output/migration.log)

source "$(dirname "$0")/common.sh"
SYNC=false
if [ "${1:-}" = --sync ]; then SYNC=true; shift; fi
if [ $# -gt 0 ]; then repos=$(printf '%s\n' "$@" | tr '[:upper:]' '[:lower:]'); else repos=$(list_repos SOURCE "$SOURCE_PROJECT") || exit 1; fi
PARALLEL=${PARALLEL:-1}
[[ "$PARALLEL" =~ ^[1-9][0-9]*$ ]] || { echo "PARALLEL in .env must be a number (1, 2, 3...)"; exit 1; }

TOTAL=$(echo "$repos" | grep -c .)
INDEX=0; already=0
RESULTS="$OUT/.results"   # one line per repository of this run: OK|SKIPPED|FAILED <slug>
: >"$RESULTS"
mkdir -p "$OUT/logs"
# output/progress/: what scripts/status.sh shows (_run = this run, one file per repository being copied)
rm -rf "$OUT/progress"; mkdir -p "$OUT/progress"
printf 'total=%s\nstarted=%s\n' "$TOTAL" "$(date '+%Y-%m-%d %H:%M:%S')" >"$OUT/progress/_run"

# migrate_one SLUG: copies one repository and records its result
migrate_one() {
  GIT_LOG="$OUT/logs/$1.log"; : >"$GIT_LOG"
  migrate_repo "$1" "$1"
  local rc=$?
  progress_clear "$1"
  case $rc in
    0) echo "OK $1" >>"$RESULTS"; grep -qx "$1" "$DONE" || echo "$1" >>"$DONE" ;;
    2) echo "SKIPPED $1" >>"$RESULTS" ;;
    *) echo "FAILED $1" >>"$RESULTS" ;;
  esac
}

log "=== migration of $TOTAL repositories: $SOURCE_PROJECT -> $TARGET_PROJECT (sync: $SYNC, parallel: $PARALLEL)"
for slug in $repos; do
  INDEX=$((INDEX + 1))
  if [ "$SYNC" = false ] && grep -qx "$slug" "$DONE"; then
    already=$((already + 1))
    continue
  fi
  if [ "$PARALLEL" = 1 ]; then
    migrate_one "$slug"
  else
    # wait for a free slot, then copy this repository in the background
    while [ "$(jobs -rp | wc -l)" -ge "$PARALLEL" ]; do sleep 1; done
    migrate_one "$slug" &
  fi
done
wait

ok=$(grep -c '^OK ' "$RESULTS")
failed=$(grep -c '^FAILED ' "$RESULTS")
skipped=$(($(grep -c '^SKIPPED ' "$RESULTS") + already))
echo "finished=$(date '+%Y-%m-%d %H:%M:%S')" >>"$OUT/progress/_run"
log "=== finished: $ok migrated, $skipped skipped, $failed failed (details in $LOG)"
echo "$(date '+%Y-%m-%d %H:%M:%S')  finished: $ok migrated, $skipped skipped, $failed failed" >"$PROGRESS"
[ "$failed" = 0 ] || { echo "Run the same command again to retry the failed repositories."; exit 1; }
