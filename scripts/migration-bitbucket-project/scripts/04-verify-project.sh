#!/usr/bin/env bash
# Checks that every source repository has an identical copy on the target: same branches
# and tags pointing to the same commit ids (a commit id is a hash of the content and the
# whole history, so same ids = same repository). Changes nothing.
# Usage: scripts/04-verify-project.sh [--lfs] [repo-slug ...]
#   --lfs  also downloads every Git LFS file from the target (git-lfs checks each file's
#          sha256): slow, it transfers all the LFS data

source "$(dirname "$0")/common.sh"
CHECK_LFS=false
if [ "${1:-}" = --lfs ]; then CHECK_LFS=true; shift; fi
if [ $# -gt 0 ]; then repos=$(printf '%s\n' "$@" | tr '[:upper:]' '[:lower:]'); else repos=$(list_repos SOURCE "$SOURCE_PROJECT") || exit 1; fi

TOTAL=$(echo "$repos" | grep -c .)
INDEX=0; identical=0; different=0
log "=== verification of $TOTAL repositories (LFS download: $CHECK_LFS)"
for slug in $repos; do
  INDEX=$((INDEX + 1))
  progress "$slug" "comparing branches and tags"
  if ! src_refs=$(refs "$(source_git "$slug")") || ! tgt_refs=$(refs "$(target_git "$slug")"); then
    log "DIFFERENT $slug: missing on the target (or not readable)"
    different=$((different + 1))
    continue
  fi
  missing=$(comm -23 <(echo "$src_refs") <(echo "$tgt_refs") | grep -c .)
  extra=$(comm -13 <(echo "$src_refs") <(echo "$tgt_refs") | grep -c .)
  if [ "$missing" != 0 ]; then
    log "DIFFERENT $slug: $missing branches/tags missing or different on the target"
    different=$((different + 1))
    continue
  fi
  [ "$extra" != 0 ] && log "INFO $slug: $extra branches/tags exist only on the target (deleted on the source since the copy)"

  if [ "$CHECK_LFS" = true ]; then
    progress "$slug" "downloading all Git LFS files from the target"
    dir="$WORK/verify-$slug.git"
    rm -rf "$dir"
    git init -q --bare "$dir" && git -C "$dir" remote add target "$(target_git "$slug")"
    if ! git -C "$dir" fetch -q target '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*' ||
      ! git -C "$dir" -c lfs.url="$(target_git "$slug")/info/lfs" lfs fetch --all target; then
      log "DIFFERENT $slug: some Git LFS files cannot be downloaded from the target"
      different=$((different + 1))
      rm -rf "$dir"
      continue
    fi
    rm -rf "$dir"
  fi
  log "IDENTICAL $slug"
  identical=$((identical + 1))
done

for slug in $repos; do progress_clear "$slug"; done
log "=== verification finished: $identical identical, $different different"
echo "$(date '+%Y-%m-%d %H:%M:%S')  verification finished: $identical identical, $different different" >"$PROGRESS"
[ "$different" = 0 ] || { echo "Update the different ones with: scripts/03-migrate-project.sh --sync <repo-slug ...>"; exit 1; }
