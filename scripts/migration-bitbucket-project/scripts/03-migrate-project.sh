#!/usr/bin/env bash
# Migrates all repositories of the project (branches, tags, Git LFS files, default branch).
# Run it again after an error or an interruption: migrated repositories are skipped.
# Usage: scripts/03-migrate-project.sh [--sync] [repo-slug ...]
#   --sync     also update the repositories already migrated with what changed on the source
#   repo-slug  migrate only these repositories
# Follow it live from another terminal: tail -f output/migration.log

source "$(dirname "$0")/common.sh"
SYNC=false
if [ "${1:-}" = --sync ]; then SYNC=true; shift; fi
if [ $# -gt 0 ]; then repos=$(printf '%s\n' "$@"); else repos=$(list_repos SOURCE "$SOURCE_PROJECT") || exit 1; fi

TOTAL=$(echo "$repos" | grep -c .)
INDEX=0; ok=0; skipped=0; failed=0
log "=== migration of $TOTAL repositories: $SOURCE_PROJECT -> $TARGET_PROJECT (sync: $SYNC)"
for slug in $repos; do
  INDEX=$((INDEX + 1))
  if [ "$SYNC" = false ] && grep -qx "$slug" "$DONE"; then
    skipped=$((skipped + 1))
    continue
  fi
  migrate_repo "$slug" "$slug"
  case $? in
    0) ok=$((ok + 1)); grep -qx "$slug" "$DONE" || echo "$slug" >>"$DONE" ;;
    2) skipped=$((skipped + 1)) ;;
    *) failed=$((failed + 1)) ;;
  esac
done

log "=== finished: $ok migrated, $skipped skipped, $failed failed (details in $LOG)"
echo "$(date '+%Y-%m-%d %H:%M:%S')  finished: $ok migrated, $skipped skipped, $failed failed" >"$PROGRESS"
[ "$failed" = 0 ] || { echo "Run the same command again to retry the failed repositories."; exit 1; }
