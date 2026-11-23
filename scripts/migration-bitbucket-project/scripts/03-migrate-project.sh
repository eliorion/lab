#!/usr/bin/env bash
#
# 03-migrate-project.sh - migrates ALL repositories of SOURCE_PROJECT_KEY to TARGET_PROJECT_KEY
# (branches, tags, Git LFS objects, default branch), one repository at a time.
#
# Resumable: every successful repository is recorded in state/<SRC>_to_<TGT>.done and
# skipped on the next run. Just run the script again after a failure or an interruption.
# For the final delta sync before the cut-over use --sync (and --prune).
#
# Usage: scripts/03-migrate-project.sh [options] [REPO_SLUG ...]
#   REPO_SLUG ...          migrate only these repositories
#   -f, --repos-file FILE  migrate only the repositories listed in FILE (one slug per line)
#   --no-resume            also process the repositories already recorded as migrated
#   --sync                 EXISTING_REPO_POLICY=sync: push again into existing target repositories
#                          (force-updates branches/tags changed on the source since the migration)
#   --prune                with --sync: also delete on the target branches/tags deleted on the source
#   --dry-run              show what would be done, change nothing
#   -y, --yes              do not ask for confirmation
#   --env FILE             use another configuration file

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/checks.sh
source "$SCRIPT_DIR/lib/checks.sh"
# shellcheck source=lib/repo.sh
source "$SCRIPT_DIR/lib/repo.sh"

RESUME=true; DRY_RUN=false; REPOS_FILE=""; OPT_SYNC=false; OPT_PRUNE=false
declare -a ONLY=()
usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
while [ $# -gt 0 ]; do
  case "$1" in
    -f | --repos-file) REPOS_FILE="$2"; shift ;;
    --no-resume) RESUME=false ;;
    --sync) OPT_SYNC=true ;;
    --prune) OPT_PRUNE=true ;;
    --dry-run) DRY_RUN=true ;;
    -y | --yes) ASSUME_YES=true ;;
    --env) ENV_FILE="$2"; shift ;;
    -h | --help) usage 0 ;;
    -*) echo "Unknown option: $1" >&2; usage 1 ;;
    *) ONLY+=("$1") ;;
  esac
  shift
done

init_config
[ "$OPT_SYNC" = true ] && EXISTING_REPO_POLICY=sync
[ "$OPT_PRUNE" = true ] && SYNC_PRUNE=true
start_run "migrate"
run_preflight

# ---- build the list of repositories ----------------------------------------------------
if [ -n "$REPOS_FILE" ]; then
  [ -f "$REPOS_FILE" ] || die "File not found: $REPOS_FILE"
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"; line="${line//[[:space:]]/}"
    [ -n "$line" ] && ONLY+=("$line")
  done <"$REPOS_FILE"
fi

ALL_SLUGS="$TMP_DIR/all_slugs"
awk -F'\t' '$2 == "git" { print $1 }' "$SOURCE_REPOS_FILE" >"$ALL_SLUGS"
CANDIDATES="$TMP_DIR/candidates"
if [ "${#ONLY[@]}" -gt 0 ]; then
  : >"$CANDIDATES"
  for s in "${ONLY[@]}"; do
    if grep -qxF -- "$s" "$ALL_SLUGS"; then
      echo "$s" >>"$CANDIDATES"
    else
      log_warn "'$s' is not a git repository of $SOURCE_PROJECT_KEY: ignored"
    fi
  done
else
  cp "$ALL_SLUGS" "$CANDIDATES"
fi

declare -a TODO=()
N_DONE=0; N_EXCL=0
while IFS= read -r s; do
  if is_excluded "$s"; then
    N_EXCL=$((N_EXCL + 1))
    printf '  excluded          %s\n' "$s" >>"$MAIN_LOG"
    continue
  fi
  if [ "$RESUME" = true ] && [ "$EXISTING_REPO_POLICY" != sync ] && [ -n "$(state_target_slug "$s")" ]; then
    N_DONE=$((N_DONE + 1))
    printf '  already migrated  %s\n' "$s" >>"$MAIN_LOG"
    continue
  fi
  TODO+=("$s")
done < <(awk '!seen[$0]++' "$CANDIDATES")
TOTAL=${#TODO[@]}

section "Migration plan"
log_info "source : $SOURCE_URL  project $SOURCE_PROJECT_KEY ($(wc -l <"$ALL_SLUGS" | tr -d ' ') git repositories)"
log_info "target : $TARGET_URL  project $TARGET_PROJECT_KEY"
log_info "to migrate now     : $TOTAL"
log_info "already migrated   : $N_DONE (state file $(state_file))"
log_info "excluded           : $N_EXCL"
log_info "existing on target : EXISTING_REPO_POLICY=$EXISTING_REPO_POLICY$([ "$EXISTING_REPO_POLICY" = sync ] && printf ' (SYNC_PRUNE=%s)' "$SYNC_PRUNE")"
log_info "Git LFS            : MIGRATE_LFS=$MIGRATE_LFS, TARGET_ENABLE_LFS=$TARGET_ENABLE_LFS, LFS_ALLOW_MISSING=$LFS_ALLOW_MISSING"
if [ "$TOTAL" -eq 0 ]; then
  log_ok "Nothing to do."
  exit 0
fi

if [ "$DRY_RUN" = true ]; then
  section "Dry run - nothing will be changed"
  for s in "${TODO[@]}"; do
    if [ -n "$TARGET_REPOS_FILE" ] && cut -f1 "$TARGET_REPOS_FILE" | grep -qxF -- "$s"; then
      action="exists on target -> $EXISTING_REPO_POLICY"
    else
      action="create + push"
    fi
    printf '  %-50s %s\n' "$s" "$action"
  done
  exit 0
fi

confirm "Migrate $TOTAL repositories from $SOURCE_PROJECT_KEY to $TARGET_PROJECT_KEY on $TARGET_URL?" || die "Aborted"

# ---- migration loop --------------------------------------------------------------------
REPORT_CSV="$RUN_LOG_DIR/report.csv"
FAILURES_TSV="$RUN_LOG_DIR/failures.tsv"
report_header >"$REPORT_CSV"
: >"$FAILURES_TSV"
N_OK=0; N_SKIP=0; N_FAIL=0; CONSECUTIVE=0; I=0
RUN_START=$SECONDS
STOPPED=false
status_begin "migration $SOURCE_PROJECT_KEY -> $TARGET_PROJECT_KEY (policy $EXISTING_REPO_POLICY)" "$TOTAL" "$REPORT_CSV"
log_info "live progress: $STATUS_FILE   (or run scripts/watch-progress.sh in another terminal)"

for s in "${TODO[@]}"; do
  I=$((I + 1))
  eta=""
  if [ "$I" -gt 1 ]; then
    elapsed=$((SECONDS - RUN_START))
    eta=" - elapsed $(human_duration "$elapsed"), ETA ~$(human_duration $((elapsed * (TOTAL - I + 1) / (I - 1))))"
  fi
  section "[$I/$TOTAL] $s$eta"
  rows_before="$(wc -l <"$REPORT_CSV")"
  STATUS_INDEX=$I

  # Each repository runs in a subshell: an unexpected error cannot stop the whole run.
  (
    migrate_repo "$s"
    rc=$?
    [ "$rc" -eq 0 ] && state_record "$s" "$R_TARGET_SLUG"
    [ "$rc" -eq 1 ] && printf '%s\t%s\n' "$s" "$R_MESSAGE" >>"$FAILURES_TSV"
    exit "$rc"
  )
  rc=$?
  if [ "$(wc -l <"$REPORT_CSV")" -eq "$rows_before" ]; then
    printf '%s,,FAILED,0,0,0,0,,0,"unexpected error (exit code %s)"\n' "$(csv_field "$s")" "$rc" >>"$REPORT_CSV"
    [ "$rc" -ne 130 ] && printf '%s\tunexpected error (exit code %s)\n' "$s" "$rc" >>"$FAILURES_TSV"
    [ "$rc" -eq 0 ] && rc=1
  fi
  [ "$rc" -eq 130 ] && die "Interrupted - run the script again to resume"

  case "$rc" in
    0) N_OK=$((N_OK + 1)); CONSECUTIVE=0 ;;
    2) N_SKIP=$((N_SKIP + 1)); CONSECUTIVE=0 ;;
    *) N_FAIL=$((N_FAIL + 1)); CONSECUTIVE=$((CONSECUTIVE + 1)) ;;
  esac
  STATUS_OK=$N_OK; STATUS_SKIP=$N_SKIP; STATUS_FAIL=$N_FAIL; STATUS_REPO=""
  status_write

  if [ "$MAX_CONSECUTIVE_FAILURES" -gt 0 ] && [ "$CONSECUTIVE" -ge "$MAX_CONSECUTIVE_FAILURES" ]; then
    log_error "$CONSECUTIVE failures in a row: stopping (server down? credentials expired?). Fix the problem and run the script again."
    STOPPED=true
    break
  fi
  free="$(free_space_gb "$WORK_DIR")"
  if [ -n "$free" ] && [ "$free" -lt 1 ]; then
    log_error "less than 1 GB free in $WORK_DIR: stopping"
    STOPPED=true
    break
  fi
done

# ---- summary ---------------------------------------------------------------------------
if [ "$STOPPED" = true ]; then status_end STOPPED
elif [ "$N_FAIL" -gt 0 ]; then status_end FINISHED_WITH_ERRORS
else status_end FINISHED; fi
section "Summary"
log_info "processed $I/$TOTAL in $(human_duration $((SECONDS - RUN_START)))"
log_info "OK: $N_OK   skipped: $N_SKIP   failed: $N_FAIL"
log_info "report: $REPORT_CSV"
log_info "logs  : $RUN_LOG_DIR"
if [ "$N_SKIP" -gt 0 ]; then
  log_warn "skipped repositories (already on the target):"
  awk -F, 'NR > 1 && $3 == "SKIPPED" { print "    " $1 }' "$REPORT_CSV" | tr -d '"' >&2
fi
if [ "$N_FAIL" -gt 0 ]; then
  log_error "failed repositories:"
  while IFS=$'\t' read -r s msg; do
    log_error "    $s: $msg"
  done <"$FAILURES_TSV"
  if [ "$EXISTING_REPO_POLICY" = sync ]; then
    log_info "Fix the cause and run the same command again (in sync mode every repository is pushed again, only new data is transferred)."
  else
    log_info "Fix the cause and run the same command again: migrated repositories are skipped."
  fi
  exit 1
fi
if [ "$I" -lt "$TOTAL" ]; then
  log_warn "the run stopped before the end: run the same command again to continue"
  exit 1
fi
log_ok "Migration finished."
log_info "Next step: scripts/04-verify-project.sh (and --sync --prune for the final delta sync before the cut-over)"
