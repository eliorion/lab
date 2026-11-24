#!/usr/bin/env bash
# Checks everything before a migration and shows the amount of data. Changes nothing.
# Usage: scripts/01-check-connections.sh [--lfs]
#   --lfs  also counts the Git LFS files of every source repository (slow: downloads the git
#          data of each repository, not its LFS files, and deletes it right after)
# PARALLEL in .env = number of repositories measured at the same time (default 1)

source "$(dirname "$0")/common.sh"
COUNT_LFS=false
[ "${1:-}" = --lfs ] && COUNT_LFS=true
FAILS=0
ok()   { echo "  OK    $*"; }
fail() { echo "  FAIL  $*"; FAILS=$((FAILS + 1)); }

echo "Local tools"
for tool in git git-lfs curl; do
  command -v "$tool" >/dev/null && ok "$tool found" || fail "$tool is not installed"
done
# credentials are passed to git with GIT_CONFIG_COUNT (git >= 2.31)
[ "$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=test.key GIT_CONFIG_VALUE_0=yes git config test.key)" = yes ] &&
  ok "$(git --version)" || fail "$(git --version) is too old: git >= 2.31 is required"

# git sends the token as the password of your username
[ -n "${SOURCE_TOKEN:-}" ] && [ -z "${SOURCE_USER:-}" ] && fail "SOURCE_USER is empty in .env: git needs your Bitbucket username with the token"

for side in SOURCE TARGET; do
  if [ $side = SOURCE ]; then url=$SOURCE_URL project=$SOURCE_PROJECT; else url=$TARGET_URL project=$TARGET_PROJECT; fi
  echo
  echo "$side server: $url (project $project)"
  api $side GET "/rest/api/1.0/application-properties"
  case "$HTTP" in
    200) ok "reachable: Bitbucket $(field version)" ;;
    401 | 403) fail "credentials rejected (HTTP $HTTP)"; continue ;;
    000) fail "cannot connect (wrong URL, network or certificate problem)"; continue ;;
    *) fail "unexpected answer HTTP $HTTP (check the URL / context path)"; continue ;;
  esac
  api $side GET "/rest/api/1.0/projects/$project"
  case "$HTTP" in
    200) ok "logged in, project $project found" ;;
    401) fail "credentials rejected (HTTP 401)" ;;
    *)
      fail "project $project not found or not visible (HTTP $HTTP $(field message))"
      # show the project keys this login can see on this server
      api $side GET "/rest/api/1.0/projects?limit=1000"
      keys=$(printf '%s' "$BODY" | grep -oE '"key" *: *"[^"]*"' | sed -E 's/.*"([^"]*)"$/\1/' | tr '\n' ' ')
      if [ -n "$keys" ]; then
        echo "  INFO  project keys you can see on this server: $keys"
      else
        echo "  INFO  you cannot see any project on this server: check the login in .env"
      fi
      ;;
  esac
done

echo
echo "Permissions and repositories"
api TARGET GET "/rest/api/1.0/projects/$TARGET_PROJECT/permissions/users?limit=1"
[ "$HTTP" = 200 ] && ok "you are admin of the target project $TARGET_PROJECT" ||
  fail "you are not admin of the target project $TARGET_PROJECT (needed to create repositories)"

if src_repos=$(list_repos SOURCE "$SOURCE_PROJECT"); then
  ok "$(echo "$src_repos" | grep -c .) repositories to migrate in $SOURCE_PROJECT"
  first=$(echo "$src_repos" | head -n 1)
  if [ -n "$first" ]; then
    git ls-remote --heads "$(source_git "$first")" >/dev/null && ok "git access to the source works ($first)" ||
      fail "git access to the source failed ($first)"
  fi
  if tgt_repos=$(list_repos TARGET "$TARGET_PROJECT"); then
    both=$(comm -12 <(echo "$src_repos" | sort) <(echo "$tgt_repos" | sort) | grep -c .)
    [ "$both" = 0 ] && ok "no repository with the same name on the target yet" ||
      echo "  INFO  $both repositories already exist on the target (they will be skipped, or updated with --sync)"
  fi
else
  fail "cannot list the source repositories"
fi
echo "  INFO  free disk space for output/: $(df -h "$OUT" | awk 'NR == 2 { print $4 }') (the biggest repository + its LFS files must fit)"

# git_size SIDE PROJECT SLUG -> bytes of git data reported by Bitbucket (empty if unknown)
git_size() {
  api "$1" GET "/projects/$2/repos/$3/sizes"
  [ "$HTTP" = 200 ] && field repository | grep -E '^[0-9]+$'
}

if [ -n "${src_repos:-}" ]; then
  echo
  echo "Amount of data (details per repository in output/sizes.txt)"
  SIZES="$OUT/sizes.txt"
  echo "repository git_bytes lfs_files lfs_bytes" >"$SIZES"
  PARALLEL=${PARALLEL:-1}
  [[ "$PARALLEL" =~ ^[1-9][0-9]*$ ]] || PARALLEL=1
  # wait_slot: waits until fewer than PARALLEL repositories are being measured
  wait_slot() { while [ "$(jobs -rp | wc -l)" -ge "$PARALLEL" ]; do wait -n 2>/dev/null || sleep 1; done; }

  # size_one SLUG: adds "slug git_bytes lfs_files lfs_bytes" to sizes.txt (? = unknown, - = not counted)
  size_one() {
    local slug=$1 g lf=- lb=- tmp="$WORK/size-check-$1.git"
    g=$(git_size SOURCE "$SOURCE_PROJECT" "$slug")
    if [ "$COUNT_LFS" = true ]; then
      # git data only (no LFS files) in a temporary copy, then the LFS files listed in its history
      rm -rf "$tmp"
      if git clone -q --bare "$(source_git "$slug")" "$tmp" 2>/dev/null; then
        read -r lf lb <<<"$(lfs_total "$tmp")"
      else
        lf="?"; lb="?"
      fi
      rm -rf "$tmp"
    fi
    echo "$slug ${g:-?} $lf $lb" >>"$SIZES"
  }

  n=$(echo "$src_repos" | grep -c .); i=0
  for slug in $src_repos; do
    i=$((i + 1))
    printf '\r  counting %d/%d  %-50s' "$i" "$n" "$slug" >&2
    if [ "$PARALLEL" = 1 ]; then size_one "$slug"; else wait_slot; size_one "$slug" & fi
  done
  wait
  printf '\r%80s\r' '' >&2
  { head -n 1 "$SIZES"; tail -n +2 "$SIZES" | sort; } >"$SIZES.tmp" && mv -f "$SIZES.tmp" "$SIZES"
  read -r git_total unknown lfs_files_total lfs_total_bytes lfs_unknown <<<"$(awk 'NR > 1 {
      if ($2 ~ /^[0-9]+$/) g += $2; else gu++
      if ($3 ~ /^[0-9]+$/) { lf += $3; lb += $4 } else if ($3 == "?") lu++ }
    END { printf "%.0f %d %.0f %.0f %d", g, gu, lf, lb, lu }' "$SIZES")"
  echo "  INFO  source $SOURCE_PROJECT: $n repositories, git data $(human "$git_total")$([ "$unknown" -gt 0 ] && echo " (size unknown for $unknown)")"
  if [ "$COUNT_LFS" = true ]; then
    echo "  INFO  source $SOURCE_PROJECT: $lfs_files_total Git LFS files, $(human "$lfs_total_bytes")$([ "$lfs_unknown" -gt 0 ] && echo " (not counted for $lfs_unknown repositories that could not be read)")"
    echo "  INFO  total to copy: $(human $((git_total + lfs_total_bytes)))"
  else
    echo "  INFO  Git LFS files not counted: run scripts/01-check-connections.sh --lfs (slow)"
  fi
  echo "  INFO  biggest repositories:"
  tail -n +2 "$SIZES" | awk '{ t = ($2 ~ /^[0-9]+$/ ? $2 : 0) + ($4 ~ /^[0-9]+$/ ? $4 : 0); print t, $1 }' |
    sort -rn | head -n 5 | while read -r t r; do echo "          $(human "$t")  $r"; done

  if [ -n "${tgt_repos:-}" ]; then
    : >"$OUT/.target-sizes"
    for slug in $tgt_repos; do
      if [ "$PARALLEL" = 1 ]; then git_size TARGET "$TARGET_PROJECT" "$slug" >>"$OUT/.target-sizes"
      else wait_slot; { git_size TARGET "$TARGET_PROJECT" "$slug"; true; } >>"$OUT/.target-sizes" & fi
    done
    wait
    t_total=$(awk '{ t += $1 } END { printf "%.0f", t }' "$OUT/.target-sizes")
    echo "  INFO  target $TARGET_PROJECT: $(echo "$tgt_repos" | grep -c .) repositories, git data $(human "$t_total") (LFS files not included)"
  fi
  echo "  INFO  already migrated (output/done.txt): $(sort -u "$DONE" | grep -c .) of $n repositories"
  left=$(awk 'FILENAME == ARGV[1] { done[$1] = 1; next }
              FNR > 1 && !($1 in done) { t += ($2 ~ /^[0-9]+$/ ? $2 : 0) + ($4 ~ /^[0-9]+$/ ? $4 : 0) }
              END { printf "%.0f", t }' "$DONE" "$SIZES")
  echo "  INFO  left to copy (repositories not migrated yet): $(human "$left")$([ "$COUNT_LFS" = false ] && echo " of git data, LFS files not counted")"
fi

echo
if [ "$FAILS" -gt 0 ]; then echo "$FAILS check(s) FAILED"; exit 1; fi
echo "All checks passed. Next: scripts/02-test-single-repo.sh <repo-slug>"
