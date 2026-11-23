#!/usr/bin/env bash
#
# 01-check-connections.sh - verifies EVERYTHING needed before a migration.
# Read-only: nothing is created or modified on either server.
#
#   - local tools (git >= 2.31, git-lfs, curl, grep, awk ...) and the .env configuration
#   - both servers: reachable, version, credentials, identity
#   - source project: readable, list of repositories
#   - target project: exists, you are PROJECT_ADMIN, name collisions, branch restrictions
#   - git over HTTP(S) and Git LFS API with the configured credentials
#   - inventory of the source repositories (LFS flag + size) unless --quick
#
# Usage: scripts/01-check-connections.sh [--quick] [--env FILE]

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/checks.sh
source "$SCRIPT_DIR/lib/checks.sh"

QUICK=false
usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --quick) QUICK=true ;;
    --env) ENV_FILE="$2"; shift ;;
    -h | --help) usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
  shift
done

init_config
start_run check

check_tools
if ! check_config; then
  section "Summary"
  log_error "Fix the configuration in $ENV_FILE and run this script again."
  exit 1
fi
setup_git_env

SRC_OK=false; TGT_OK=false
check_server SOURCE && SRC_OK=true
check_server TARGET && TGT_OK=true
SRC_PROJECT_OK=false
[ "$SRC_OK" = true ] && check_source_project && SRC_PROJECT_OK=true
[ "$TGT_OK" = true ] && check_target_project

# ---- git over HTTP(S) ------------------------------------------------------------------
section "Git access"
if [ "$SRC_PROJECT_OK" = true ] && [ -s "$SOURCE_REPOS_FILE" ]; then
  sample=""
  if [ -n "$TEST_REPO_SLUG" ] && cut -f1 "$SOURCE_REPOS_FILE" | grep -qxF -- "$TEST_REPO_SLUG"; then
    sample="$TEST_REPO_SLUG"
  elif [ -n "$TEST_REPO_SLUG" ]; then
    chk_warn "TEST_REPO_SLUG=$TEST_REPO_SLUG does not exist in $SOURCE_PROJECT_KEY"
  fi
  [ -n "$sample" ] || sample="$(head -n 1 "$SOURCE_REPOS_FILE" | cut -f1)"
  check_git_access SOURCE "$SOURCE_PROJECT_KEY" "$sample"
fi
if [ "$TGT_OK" = true ] && [ -n "$TARGET_REPOS_FILE" ] && [ -s "$TARGET_REPOS_FILE" ]; then
  check_git_access TARGET "$TARGET_PROJECT_KEY" "$(head -n 1 "$TARGET_REPOS_FILE" | cut -f1)"
elif [ "$TGT_OK" = true ] && [ -n "$TARGET_REPOS_FILE" ]; then
  log_info "target project is empty: git push and LFS upload will be validated by scripts/02-test-single-repo.sh"
fi

# ---- inventory -------------------------------------------------------------------------
BIGGEST=0
if [ "$QUICK" = false ] && [ "$SRC_PROJECT_OK" = true ] && [ -s "$SOURCE_REPOS_FILE" ]; then
  section "Source inventory (LFS flag and size of every repository)"
  INVENTORY="$RUN_LOG_DIR/inventory.csv"
  echo "slug,lfs,repository_bytes,excluded,name" >"$INVENTORY"
  total=0; lfs_on=0; lfs_unknown=0; i=0; first_lfs=""
  count="$(wc -l <"$SOURCE_REPOS_FILE" | tr -d ' ')"
  while IFS=$'\t' read -r slug _ _ name; do
    i=$((i + 1))
    api_call SOURCE GET "/rest/git-lfs/admin/projects/$SOURCE_PROJECT_KEY/repos/$slug/enabled"
    case "$API_STATUS" in
      200 | 204) lfs=enabled; lfs_on=$((lfs_on + 1)); [ -n "$first_lfs" ] || first_lfs="$slug" ;;
      404) lfs=disabled ;;
      *) lfs=unknown; lfs_unknown=$((lfs_unknown + 1)) ;;
    esac
    # Not a public REST API, but present on Bitbucket Server/DC: {"repository":bytes,"attachments":bytes}
    api_call SOURCE GET "/projects/$SOURCE_PROJECT_KEY/repos/$slug/sizes"
    size=0
    [ "$API_STATUS" = 200 ] && size="$(jget .repository 0)"
    [[ "$size" =~ ^[0-9]+$ ]] || size=0
    total=$((total + size))
    [ "$size" -gt "$BIGGEST" ] && BIGGEST="$size"
    excluded=false
    is_excluded "$slug" && excluded=true
    printf '%s,%s,%s,%s,%s\n' "$slug" "$lfs" "$size" "$excluded" "$(csv_field "$name")" >>"$INVENTORY"
    [ -t 2 ] && printf '\r  %d/%d %-60s' "$i" "$count" "$slug" >&2
  done <"$SOURCE_REPOS_FILE"
  [ -t 2 ] && printf '\r%-80s\r' "" >&2
  chk_pass "inventory written to $INVENTORY"
  log_info "Git LFS enabled on $lfs_on repositories$([ "$lfs_unknown" -gt 0 ] && printf ', unknown for %s' "$lfs_unknown")"
  if [ "$lfs_unknown" -gt 0 ]; then
    log_info "(LFS flag unreadable: the token probably lacks 'Repository admin' permission. Not blocking: every repository will be scanned for LFS objects.)"
  fi
  log_info "total git size on the source: $(human_size "$total") (LFS objects not included)"
  log_info "biggest repositories:"
  tail -n +2 "$INVENTORY" | sort -t, -k3,3nr | head -n 5 | while IFS=, read -r s l b _; do
    log_info "    $(printf '%-50s %10s  LFS %s' "$s" "$(human_size "$b")" "$l")"
  done
  n_excl="$(awk -F, 'NR > 1 && $4 == "true"' "$INVENTORY" | wc -l | tr -d ' ')"
  [ "$n_excl" -gt 0 ] && log_info "$n_excl repositories match REPO_EXCLUDE and will not be migrated"
  [ -n "$first_lfs" ] && check_lfs_api SOURCE "$SOURCE_PROJECT_KEY" "$first_lfs"
fi

check_disk
if [ "$BIGGEST" -gt 0 ]; then
  free="$(free_space_gb "$WORK_DIR")"
  need_gb=$(((BIGGEST / 1024 / 1024 / 1024) + 1))
  if [ -n "$free" ] && [ "$free" -lt "$need_gb" ]; then
    chk_warn "the biggest repository needs ~${need_gb} GB (+ its LFS objects) but only ${free} GB are free"
  fi
fi

# ---- summary ---------------------------------------------------------------------------
section "Summary"
log_info "passed: $CHECK_PASS   warnings: $CHECK_WARN   failed: $CHECK_FAIL"
log_info "full log: $MAIN_LOG"
if [ "$CHECK_FAIL" -gt 0 ]; then
  log_error "Some checks FAILED: fix them before migrating."
  exit 1
fi
if [ "$CHECK_WARN" -gt 0 ]; then
  log_warn "All blocking checks passed, review the warnings above."
else
  log_ok "All checks passed."
fi
log_info "Next step: scripts/02-test-single-repo.sh <repo-slug>   (pick a repository that uses Git LFS)"
