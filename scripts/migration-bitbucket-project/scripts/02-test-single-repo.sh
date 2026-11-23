#!/usr/bin/env bash
# Migrates ONE repository as a test copy named "<slug>-migration-test", then downloads it
# back from the target (with all its Git LFS files) to prove the copy is complete.
# Usage: scripts/02-test-single-repo.sh <repo-slug>

source "$(dirname "$0")/common.sh"
slug=${1:?Usage: $0 <repo-slug>}
test_slug="$slug-migration-test"

log "=== test: $SOURCE_PROJECT/$slug -> $TARGET_PROJECT/$test_slug"
migrate_repo "$slug" "$test_slug" "$test_slug" || exit 1

progress "$slug" "downloading the copy back from the target"
dir="$WORK/$test_slug.git"
rm -rf "$dir"
git init -q --bare "$dir" && git -C "$dir" remote add target "$(target_git "$test_slug")"
git -C "$dir" fetch target '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*' &&
  git -C "$dir" -c lfs.url="$(target_git "$test_slug")/info/lfs" lfs fetch --all target ||
  { log "TEST FAILED: cannot download the copy back from the target"; exit 1; }
back=$(find "$dir/lfs/objects" -type f 2>/dev/null | wc -l | tr -d ' ')
rm -rf "$dir"
[ "$back" = "$LFS_FILES" ] || { log "TEST FAILED: $LFS_FILES LFS files on the source but $back downloaded from the target"; exit 1; }
log "TEST OK: branches, tags and $back LFS files identical. Browse: $TARGET_URL/projects/$TARGET_PROJECT/repos/$test_slug"

read -r -p "Delete the test repository $TARGET_PROJECT/$test_slug from the target? [y/N] " answer
if [ "$answer" = y ] || [ "$answer" = Y ]; then
  api TARGET DELETE "/rest/api/1.0/projects/$TARGET_PROJECT/repos/$test_slug"
  log "test repository deleted (HTTP $HTTP)"
fi
