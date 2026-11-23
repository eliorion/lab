#!/usr/bin/env bash
#
# 02-test-single-repo.sh - migrates ONE repository as a test and verifies it end to end.
#
# By default the copy is created on the target under a TEST name
# ("<name><TEST_TARGET_SUFFIX>", e.g. "my-repo-migration-test") so it never collides
# with the real migration. You are offered to delete it at the end.
#
# Verification:
#   - every branch and tag on the target points to the same object as on the source
#   - every Git LFS object exists on the target (LFS batch API)
#   - round trip: a fresh copy fetched FROM THE TARGET downloads all LFS objects again
#     (git-lfs checks their sha256) and the list is compared with the source
#
# Usage: scripts/02-test-single-repo.sh [REPO_SLUG] [options]
#   REPO_SLUG            source repository (default: TEST_REPO_SLUG from .env)
#   --same-name          use the real name (= real migration of this repository)
#   --target-name NAME   name to use on the target
#   --delete             delete the test repository from the target at the end
#   --keep               keep the test repository on the target
#   --list               list the source repositories with their LFS flag and exit
#   -y, --yes            do not ask for confirmation
#   --env FILE           use another configuration file

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/checks.sh
source "$SCRIPT_DIR/lib/checks.sh"
# shellcheck source=lib/repo.sh
source "$SCRIPT_DIR/lib/repo.sh"

SLUG=""; TGT_NAME=""; SAME_NAME=false; AFTER=ask; LIST=false
usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --same-name) SAME_NAME=true ;;
    --target-name) TGT_NAME="$2"; shift ;;
    --delete) AFTER=delete ;;
    --keep) AFTER=keep ;;
    --list) LIST=true ;;
    -y | --yes) ASSUME_YES=true ;;
    --env) ENV_FILE="$2"; shift ;;
    -h | --help) usage 0 ;;
    -*) echo "Unknown option: $1" >&2; usage 1 ;;
    *) SLUG="$1" ;;
  esac
  shift
done

init_config
start_run "test"
run_preflight

if [ "$LIST" = true ]; then
  section "Source repositories in $SOURCE_PROJECT_KEY"
  while IFS=$'\t' read -r s _; do
    api_call SOURCE GET "/rest/git-lfs/admin/projects/$SOURCE_PROJECT_KEY/repos/$s/enabled"
    case "$API_STATUS" in 200 | 204) l="LFS" ;; 404) l="-" ;; *) l="?" ;; esac
    printf '%-4s %s\n' "$l" "$s"
  done <"$SOURCE_REPOS_FILE" | sort -r
  exit 0
fi

[ -n "$SLUG" ] || SLUG="$TEST_REPO_SLUG"
[ -n "$SLUG" ] || die "No repository given: scripts/02-test-single-repo.sh <repo-slug>  (or set TEST_REPO_SLUG, or use --list)"
SRC_LINE="$(awk -F'\t' -v s="$SLUG" '$1 == s' "$SOURCE_REPOS_FILE")"
if [ -z "$SRC_LINE" ]; then
  log_error "Repository '$SLUG' not found in $SOURCE_PROJECT_KEY. Similar names:"
  cut -f1 "$SOURCE_REPOS_FILE" | grep -iF -- "${SLUG:0:4}" | head -n 10 >&2
  exit 1
fi
SRC_NAME="$(printf '%s\n' "$SRC_LINE" | cut -f4-)"

if [ "$SAME_NAME" = true ]; then
  TGT_NAME=""
  TGT_DISPLAY="$SRC_NAME (real name, EXISTING_REPO_POLICY=$EXISTING_REPO_POLICY)"
else
  [ -n "$TGT_NAME" ] || TGT_NAME="${SRC_NAME}${TEST_TARGET_SUFFIX}"
  TGT_DISPLAY="$TGT_NAME (test copy)"
  if [ "$TGT_NAME" = "$SRC_NAME" ]; then SAME_NAME=true; TGT_NAME=""; fi
fi

section "Test plan"
log_info "source : $SOURCE_URL/projects/$SOURCE_PROJECT_KEY/repos/$SLUG"
log_info "target : $TARGET_URL/projects/$TARGET_PROJECT_KEY  as  $TGT_DISPLAY"
confirm "Run the test migration?" || die "Aborted"

if [ "$SAME_NAME" = false ]; then
  guess="$(guess_slug "$TGT_NAME")"
  api_call TARGET GET "/rest/api/1.0/projects/$TARGET_PROJECT_KEY/repos/$guess"
  if [ "$API_STATUS" = 200 ]; then
    log_warn "the test repository $TARGET_PROJECT_KEY/$guess already exists on the target (previous test?)"
    confirm "Delete it and run the test again?" || die "Aborted"
    target_delete_repo "$guess" || die "Could not delete $TARGET_PROJECT_KEY/$guess"
  fi
fi

# The round trip needs the local copy of the source; the real setting is restored after.
ORIG_KEEP_WORKDIR="$KEEP_WORKDIR"
KEEP_WORKDIR=true
VERIFY_LFS=true
RT_DIR=""
on_exit_hook() {
  [ -n "$RT_DIR" ] && rm -rf "$RT_DIR"
  if [ "$ORIG_KEEP_WORKDIR" != true ] && [ -n "$REPO_WORK" ]; then rm -rf "$REPO_WORK"; fi
}

REPORT_CSV="$RUN_LOG_DIR/report.csv"
report_header >"$REPORT_CSV"
section "Migration of $SLUG"
status_begin "test migration of $SLUG" 1 "$REPORT_CSV"
STATUS_INDEX=1
migrate_repo "$SLUG" "$TGT_NAME"
RC=$?
if [ "$RC" -ne 0 ]; then
  STATUS_FAIL=1; status_end FAILED
  section "Result"
  log_error "Test FAILED: $R_MESSAGE"
  log_info "Last lines of $REPO_LOG:"
  tail -n 25 "$REPO_LOG" >&2
  exit 1
fi

# ---- round trip from the target ------------------------------------------------------
section "Round-trip verification (fresh copy fetched from the target)"
FAILS=0
TGT_URL="$(git_url TARGET "$TARGET_PROJECT_KEY" "$R_TARGET_SLUG")"
RT_DIR="$WORK_DIR/_roundtrip/$R_TARGET_SLUG.git"
rm -rf "$RT_DIR"
run_logged git init --bare --quiet "$RT_DIR"
git -C "$RT_DIR" config remote.target.url "$TGT_URL"
git -C "$RT_DIR" config --add remote.target.fetch '+refs/heads/*:refs/heads/*'
git -C "$RT_DIR" config --add remote.target.fetch '+refs/tags/*:refs/tags/*'
git -C "$RT_DIR" config remote.target.tagOpt --no-tags

status_step "round trip: downloading the copy back from the target (git)"
if run_retry git -C "$RT_DIR" fetch --progress target; then
  if diff <(local_refs "$REPO_WORK") <(local_refs "$RT_DIR") >>"$REPO_LOG"; then
    log_ok "fresh fetch from the target: $R_BRANCHES branches and $R_TAGS tags identical to the source"
  else
    log_error "branches/tags fetched from the target differ from the source (see $REPO_LOG)"
    FAILS=$((FAILS + 1))
  fi
else
  log_error "git fetch from the target failed: $(log_tail 3)"
  FAILS=$((FAILS + 1))
fi

if [ -n "$R_DEFAULT_BRANCH" ]; then
  tgt_head="$(git ls-remote --symref "$TGT_URL" HEAD 2>>"$REPO_LOG" | awk '/^ref:/ { print $2; exit }')"
  if [ "$tgt_head" = "refs/heads/$R_DEFAULT_BRANCH" ]; then
    log_ok "default branch on the target: $R_DEFAULT_BRANCH"
  else
    log_warn "default branch on the target is '${tgt_head#refs/heads/}', expected '$R_DEFAULT_BRANCH'"
  fi
fi

if [ "$R_LFS_OBJECTS" -gt 0 ]; then
  api_call TARGET GET "/rest/git-lfs/admin/projects/$TARGET_PROJECT_KEY/repos/$R_TARGET_SLUG/enabled"
  case "$API_STATUS" in
    200 | 204) log_ok "Git LFS is enabled on the target repository" ;;
    *) log_error "Git LFS does not look enabled on the target repository: $(api_err_msg)"; FAILS=$((FAILS + 1)) ;;
  esac
  log_info "downloading the $R_LFS_OBJECTS LFS objects back from the target ($(human_size "$R_LFS_BYTES"))"
  status_step "round trip: downloading the $R_LFS_OBJECTS LFS objects back from the target"
  if run_retry git -C "$RT_DIR" -c lfs.url="$TGT_URL/info/lfs" lfs fetch --all target; then
    if diff <(list_local_lfs_objects "$REPO_WORK") <(list_local_lfs_objects "$RT_DIR") >>"$REPO_LOG"; then
      log_ok "all $R_LFS_OBJECTS LFS objects downloaded from the target and identical to the source"
    else
      log_error "LFS objects downloaded from the target differ from the source (see $REPO_LOG)"
      FAILS=$((FAILS + 1))
    fi
  else
    log_error "git lfs fetch from the target failed: $(log_tail 3)"
    FAILS=$((FAILS + 1))
  fi
else
  log_info "this repository has no LFS objects: pick a repository that uses LFS to test the LFS part"
fi

# ---- summary -------------------------------------------------------------------------
section "Result"
git_kb="$(du -sk "$REPO_WORK" 2>/dev/null | awk '{print $1}')"
log_info "repository : $SOURCE_PROJECT_KEY/$SLUG -> $TARGET_PROJECT_KEY/$R_TARGET_SLUG"
log_info "content    : $R_BRANCHES branches, $R_TAGS tags, $R_LFS_OBJECTS LFS objects"
log_info "data       : $(human_size $((${git_kb:-0} * 1024))) transferred in $(human_duration "$R_DURATION") (migration step only)"
log_info "browse     : $TARGET_URL/projects/$TARGET_PROJECT_KEY/repos/$R_TARGET_SLUG/browse"
log_info "log        : $REPO_LOG"

if [ "$FAILS" -gt 0 ]; then
  STATUS_FAIL=1; status_end FAILED
  log_error "Test FAILED ($FAILS verification error(s)). The target repository was kept for investigation."
  exit 1
fi
log_ok "Test PASSED"
STATUS_OK=1; status_end FINISHED

if [ "$SAME_NAME" = true ]; then
  state_record "$SLUG" "$R_TARGET_SLUG"
  log_info "real name used: recorded as migrated, 03-migrate-project.sh will not migrate it again"
  exit 0
fi
case "$AFTER" in
  delete) do_delete=true ;;
  keep) do_delete=false ;;
  *)
    do_delete=false
    if [ -t 0 ]; then
      log_info "Check the copy in the web UI first if you want: $TARGET_URL/projects/$TARGET_PROJECT_KEY/repos/$R_TARGET_SLUG/browse"
      if ASSUME_YES=false confirm "Delete the test repository $TARGET_PROJECT_KEY/$R_TARGET_SLUG from the target now?"; then do_delete=true; fi
    fi
    ;;
esac
if [ "$do_delete" = true ]; then
  target_delete_repo "$R_TARGET_SLUG" && log_ok "test repository $TARGET_PROJECT_KEY/$R_TARGET_SLUG deleted"
else
  log_info "test repository kept: $TARGET_PROJECT_KEY/$R_TARGET_SLUG (delete it later from the web UI: Repository settings > Delete repository)"
fi
log_info "Next step: scripts/03-migrate-project.sh"
