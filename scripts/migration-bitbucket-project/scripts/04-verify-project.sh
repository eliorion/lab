#!/usr/bin/env bash
#
# 04-verify-project.sh - proves that every target repository is an exact copy of its source.
# Read-only on BOTH servers. For each repository:
#   - the target repository exists
#   - every branch and tag points to the same commit/tag id on both servers (a git id is a
#     SHA hash of the whole content and history: same id = identical content)
#   - no extra branch/tag on the target, same default branch, Git LFS enabled on the target
#   --deep          also downloads all branches/tags FROM THE TARGET (git verifies every object
#                   while downloading) and checks that every Git LFS object referenced anywhere
#                   in the history exists on the target with the right size (LFS API, no download)
#   --download-lfs  like --deep, and also downloads every LFS object from the target;
#                   git-lfs checks the sha256 of each file (slow: transfers all LFS data)
# Run it after the migration and right before the cut-over.
#
# Usage: scripts/04-verify-project.sh [--deep | --download-lfs] [REPO_SLUG ...] [--env FILE]

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/checks.sh
source "$SCRIPT_DIR/lib/checks.sh"
# shellcheck source=lib/repo.sh
source "$SCRIPT_DIR/lib/repo.sh"

declare -a ONLY=()
DEEP=false; DOWNLOAD_LFS=false
usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --deep) DEEP=true ;;
    --download-lfs) DEEP=true; DOWNLOAD_LFS=true ;;
    --env) ENV_FILE="$2"; shift ;;
    -h | --help) usage 0 ;;
    -*) echo "Unknown option: $1" >&2; usage 1 ;;
    *) ONLY+=("$1") ;;
  esac
  shift
done

init_config
start_run "verify"
run_preflight

REPORT="$RUN_LOG_DIR/verify.csv"
echo "source_slug,target_slug,status,source_refs,target_refs,missing_or_different,extra_on_target,default_branch_source,default_branch_target,lfs_source,lfs_target,lfs_objects_in_history,lfs_missing_on_target,lfs_missing_on_source_too" >"$REPORT"
DETAILS="$RUN_LOG_DIR/verify-details.log"
: >"$DETAILS"
REPO_LOG="$DETAILS"      # used by the lfs_* helpers of lib/repo.sh
VERIFY_DIR=""
on_exit_hook() { [ -n "$VERIFY_DIR" ] && rm -rf "$VERIFY_DIR"; }

ls_refs() { git ls-remote --refs "$1" 2>>"$DETAILS" | awk '$2 ~ /^refs\/(heads|tags)\// { print $1, $2 }' | sort; }
head_of() { git ls-remote --symref "$1" HEAD 2>>"$DETAILS" | awk '/^ref:/ { sub("refs/heads/", "", $2); print $2; exit }'; }
lfs_flag() {
  api_call "$1" GET "/rest/git-lfs/admin/projects/$2/repos/$3/enabled"
  case "$API_STATUS" in 200 | 204) echo on ;; 404) echo off ;; *) echo unknown ;; esac
}

declare -a SLUGS=()
if [ "${#ONLY[@]}" -gt 0 ]; then
  SLUGS=("${ONLY[@]}")
else
  while IFS= read -r s; do is_excluded "$s" || SLUGS+=("$s"); done < <(awk -F'\t' '$2 == "git" { print $1 }' "$SOURCE_REPOS_FILE")
fi

LEVEL="refs, default branch, LFS flag"
[ "$DEEP" = true ] && LEVEL="$LEVEL + full download from the target + every LFS object of the history"
[ "$DOWNLOAD_LFS" = true ] && LEVEL="$LEVEL (downloaded, sha256 checked)"
section "Verifying ${#SLUGS[@]} repositories ($LEVEL)"
N_OK=0; N_DIFF=0; N_MISSING=0; N_ERR=0; N_LFS_TOTAL=0; I=0
status_begin "verification ($LEVEL)" "${#SLUGS[@]}" "$REPORT"
export GIT_LFS_PROGRESS="$RUN_LOG_DIR/lfs-progress.log"
for s in "${SLUGS[@]}"; do
  I=$((I + 1))
  STATUS_OK=$N_OK; STATUS_FAIL=$((N_DIFF + N_MISSING + N_ERR))
  status_repo "$I" "$s" "$DETAILS" "$GIT_LFS_PROGRESS"
  status_step "comparing branches, tags and default branch"
  R_SOURCE_SLUG="$s"
  t="$(state_target_slug "$s")"
  [ -n "$t" ] || t="$s"
  src_url="$(git_url SOURCE "$SOURCE_PROJECT_KEY" "$s")"
  tgt_url="$(git_url TARGET "$TARGET_PROJECT_KEY" "$t")"
  echo "== $s -> $TARGET_PROJECT_KEY/$t" >>"$DETAILS"

  api_call TARGET GET "/rest/api/1.0/projects/$TARGET_PROJECT_KEY/repos/$t"
  if [ "$API_STATUS" = 404 ]; then
    N_MISSING=$((N_MISSING + 1))
    log_error "[$I/${#SLUGS[@]}] $s: MISSING on the target"
    printf '%s,%s,MISSING,,,,,,,,,,,\n' "$s" "$t" >>"$REPORT"
    continue
  fi

  src_refs="$TMP_DIR/src_refs"; tgt_refs="$TMP_DIR/tgt_refs"
  if ! ls_refs "$src_url" >"$src_refs" || ! ls_refs "$tgt_url" >"$tgt_refs"; then
    N_ERR=$((N_ERR + 1))
    log_error "[$I/${#SLUGS[@]}] $s: ERROR while listing refs (see $DETAILS)"
    printf '%s,%s,ERROR,,,,,,,,,,,\n' "$s" "$t" >>"$REPORT"
    continue
  fi
  ns="$(wc -l <"$src_refs" | tr -d ' ')"
  nt="$(wc -l <"$tgt_refs" | tr -d ' ')"
  missing="$(comm -23 "$src_refs" "$tgt_refs" | wc -l | tr -d ' ')"
  extra="$(comm -13 <(awk '{print $2}' "$src_refs" | sort) <(awk '{print $2}' "$tgt_refs" | sort) | wc -l | tr -d ' ')"
  hs="$(head_of "$src_url")"; ht="$(head_of "$tgt_url")"
  lfs_s="$(lfs_flag SOURCE "$SOURCE_PROJECT_KEY" "$s")"; lfs_t="$(lfs_flag TARGET "$TARGET_PROJECT_KEY" "$t")"

  problems=""
  [ "$missing" -gt 0 ] && problems="$problems $missing branches/tags missing or different on the target;"
  [ "$extra" -gt 0 ] && problems="$problems $extra branches/tags on the target that no longer exist on the source;"
  [ "$ns" -gt 0 ] && [ "$hs" != "$ht" ] && problems="$problems default branch $hs vs ${ht:-none};"
  [ "$lfs_s" = on ] && [ "$lfs_t" != on ] && problems="$problems LFS not enabled on the target;"
  if [ -n "$problems" ]; then
    comm -3 "$src_refs" "$tgt_refs" | sed 's/^\t/    target: /; s/^\([0-9a-f]\)/    source: \1/' >>"$DETAILS"
  fi

  # ---- deep verification: everything downloaded from the target ------------------------
  n_ptr=""; miss_t=""; miss_s=""; info=""
  if [ "$DEEP" = true ] && [ "$ns" -gt 0 ]; then
    VERIFY_DIR="$WORK_DIR/_verify/$t.git"
    rm -rf "$VERIFY_DIR"
    git init --bare --quiet "$VERIFY_DIR"
    git -C "$VERIFY_DIR" config remote.target.url "$tgt_url"
    status_step "deep check: downloading every branch and tag from the target (git)"
    if ! git -C "$VERIFY_DIR" fetch --progress --no-tags target '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*' 2>>"$DETAILS"; then
      problems="$problems cannot download the repository from the target;"
    else
      if ! diff <(local_refs "$VERIFY_DIR") "$src_refs" >>"$DETAILS"; then
        problems="$problems history downloaded from the target differs from the source;"
      fi
      status_step "deep check: listing the Git LFS objects of the whole history"
      list_lfs_pointers "$VERIFY_DIR" >"$TMP_DIR/ptrs"
      n_ptr="$(wc -l <"$TMP_DIR/ptrs" | tr -d ' ')"
      miss_t=0; miss_s=0
      if [ "$n_ptr" -gt 0 ]; then
        N_LFS_TOTAL=$((N_LFS_TOTAL + n_ptr))
        status_step "deep check: asking the target for $n_ptr LFS objects"
        if ! miss_t="$(lfs_missing_on TARGET "$TARGET_PROJECT_KEY" "$t" "$TMP_DIR/ptrs" "$TMP_DIR/miss_t")"; then
          problems="$problems LFS API error on the target;"; miss_t=""
        elif [ "$miss_t" -gt 0 ]; then
          # objects missing on the target: are they missing on the source as well?
          if miss_s="$(lfs_missing_on SOURCE "$SOURCE_PROJECT_KEY" "$s" "$TMP_DIR/miss_t")"; then
            [ "$miss_t" -gt "$miss_s" ] && problems="$problems $((miss_t - miss_s)) LFS objects missing on the target;"
            [ "$miss_s" -gt 0 ] && info=" ($miss_s LFS objects are missing on the SOURCE server too: they cannot be migrated)"
          else
            problems="$problems $miss_t LFS objects missing on the target;"; miss_s=""
          fi
        fi
        if [ "$DOWNLOAD_LFS" = true ] && [ "${miss_t:-1}" -eq 0 ]; then
          status_step "deep check: downloading the $n_ptr LFS objects from the target (sha256 check)"
          if git -C "$VERIFY_DIR" -c lfs.url="$tgt_url/info/lfs" lfs fetch --all target >>"$DETAILS" 2>&1; then
            if ! diff <(list_local_lfs_objects "$VERIFY_DIR") "$TMP_DIR/ptrs" >>"$DETAILS"; then
              problems="$problems LFS objects downloaded from the target differ from the history;"
            fi
          else
            problems="$problems LFS download from the target failed;"
          fi
        fi
      fi
    fi
    rm -rf "$VERIFY_DIR"; VERIFY_DIR=""
  fi

  lfs_txt=""
  [ -n "$n_ptr" ] && lfs_txt=", $n_ptr LFS objects"
  if [ -z "$problems" ]; then
    status=IN_SYNC; N_OK=$((N_OK + 1))
    log_ok "[$I/${#SLUGS[@]}] $s: identical ($ns branches/tags$lfs_txt)$info"
  else
    status=OUT_OF_SYNC; N_DIFF=$((N_DIFF + 1))
    log_warn "[$I/${#SLUGS[@]}] $s: OUT OF SYNC:$problems$info"
    echo "   problems:$problems$info" >>"$DETAILS"
  fi
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$s" "$t" "$status" "$ns" "$nt" "$missing" "$extra" \
    "$hs" "$ht" "$lfs_s" "$lfs_t" "$n_ptr" "$miss_t" "$miss_s" >>"$REPORT"
done

STATUS_OK=$N_OK; STATUS_FAIL=$((N_DIFF + N_MISSING + N_ERR))
if [ "$STATUS_FAIL" -gt 0 ]; then status_end FINISHED_WITH_ERRORS; else status_end FINISHED; fi
section "Summary"
log_info "checked: $LEVEL"
log_info "identical: $N_OK   out of sync: $N_DIFF   missing: $N_MISSING   errors: $N_ERR"
[ "$DEEP" = true ] && log_info "LFS objects checked on the target: $N_LFS_TOTAL"
log_info "report : $REPORT"
log_info "details: $DETAILS"
if [ $((N_DIFF + N_MISSING + N_ERR)) -gt 0 ]; then
  log_warn "Changed on the source since the migration -> scripts/03-migrate-project.sh --sync"
  log_warn "Branches/tags deleted on the source but still on the target -> only --sync --prune removes them from the TARGET (the source is never modified)"
  exit 1
fi
log_ok "All repositories on the target are exact copies of the source."
