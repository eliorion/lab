#!/usr/bin/env bash
# Shared settings and functions, loaded by every script.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$ROOT/.env" ] || { echo "Missing $ROOT/.env - copy .env.example to .env and fill it in"; exit 1; }
# shellcheck source=/dev/null
source "$ROOT/.env"

SOURCE_URL="${SOURCE_URL%/}"
TARGET_URL="${TARGET_URL%/}"
TARGET_PROJECT="${TARGET_PROJECT:-$SOURCE_PROJECT}"
if [ -n "${CA_BUNDLE:-}" ]; then export CURL_CA_BUNDLE="$CA_BUNDLE" GIT_SSL_CAINFO="$CA_BUNDLE"; fi

# Everything the scripts create goes in output/
OUT="$ROOT/output"
WORK="$OUT/work"          # temporary copies, deleted after each repository
LOG="$OUT/migration.log"  # what happened (follow it live: tail -f output/migration.log)
PROGRESS="$OUT/progress.txt"
DONE="$OUT/done.txt"      # repositories already migrated (skipped on the next run)
mkdir -p "$WORK"
touch "$DONE"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG"; }

# progress SLUG STEP - shows where the copy is ($INDEX/$TOTAL are set by the calling script)
progress() {
  echo "$(date '+%Y-%m-%d %H:%M:%S')  [${INDEX:-1}/${TOTAL:-1}]  $1: $2" >"$PROGRESS"
  log "[${INDEX:-1}/${TOTAL:-1}] $1: $2"
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
basic() { printf '%s:%s' "$1" "$2" | base64 | tr -d '\n'; }

# ---- credentials ------------------------------------------------------------------------
if [ -n "${SOURCE_TOKEN:-}" ]; then
  SOURCE_AUTH="Authorization: Bearer $SOURCE_TOKEN"
else
  SOURCE_AUTH="Authorization: Basic $(basic "${SOURCE_USER:-}" "${SOURCE_PASSWORD:-}")"
fi
TARGET_AUTH="Authorization: Basic $(basic "${TARGET_USER:-}" "${TARGET_PASSWORD:-}")"

# git and git-lfs receive the credentials as HTTP headers through environment variables:
# nothing is written in a git config file or visible in the process list.
export GIT_CONFIG_COUNT=3
export GIT_CONFIG_KEY_0="http.$SOURCE_URL/.extraHeader" GIT_CONFIG_VALUE_0="$SOURCE_AUTH"
export GIT_CONFIG_KEY_1="http.$TARGET_URL/.extraHeader" GIT_CONFIG_VALUE_1="$TARGET_AUTH"
export GIT_CONFIG_KEY_2="lfs.locksverify" GIT_CONFIG_VALUE_2="false"
export GIT_TERMINAL_PROMPT=0

# ---- REST API ---------------------------------------------------------------------------
# api SOURCE|TARGET METHOD PATH [JSON]  ->  sets $HTTP (status code) and $BODY (response)
# The SOURCE server only accepts GET: the scripts can never modify it.
api() {
  local side=$1 method=$2 path=$3 data=${4:-} url auth out
  if [ "$side" = SOURCE ]; then
    [ "$method" = GET ] || { log "ERROR: refused $method on the source server (read-only)"; exit 1; }
    url=$SOURCE_URL auth=$SOURCE_AUTH
  else
    url=$TARGET_URL auth=$TARGET_AUTH
  fi
  if [ -n "$data" ]; then
    out=$(curl -sS --connect-timeout 15 -K <(echo "header = \"$auth\"") -X "$method" \
      -H 'Content-Type: application/json' -H 'X-Atlassian-Token: no-check' -d "$data" \
      -w '\n%{http_code}' "$url$path")
  else
    out=$(curl -sS --connect-timeout 15 -K <(echo "header = \"$auth\"") -X "$method" \
      -H 'X-Atlassian-Token: no-check' -w '\n%{http_code}' "$url$path")
  fi
  HTTP=${out##*$'\n'}
  BODY=${out%$'\n'*}
}

# field NAME -> first value of "NAME" in $BODY (enough for the simple answers used here)
field() {
  printf '%s' "$BODY" | grep -oE "\"$1\" *: *(\"[^\"]*\"|[^,}]*)" | head -n 1 | sed -E 's/^"[^"]*" *: *//; s/^"//; s/"$//'
}

# list_repos SOURCE|TARGET PROJECT -> one repository slug per line
list_repos() {
  local side=$1 project=$2 start=0 page
  while :; do
    api "$side" GET "/rest/api/1.0/projects/$project/repos?limit=500&start=$start"
    [ "$HTTP" = 200 ] || { echo "ERROR: cannot list the repositories of $project (HTTP $HTTP $(field message))" >&2; return 1; }
    # each repository object starts with "slug" (a fork's "origin" repository is not matched)
    page=$(printf '%s' "$BODY" | grep -oE '[[,] *\{ *"slug" *: *"[^"]*"' | sed -E 's/.*"([^"]*)"$/\1/')
    if [ -n "$page" ] && [ "$(echo "$page" | wc -l)" -ne "$(field size)" ]; then
      echo "ERROR: unexpected answer format while listing the repositories" >&2
      return 1
    fi
    [ -n "$page" ] && echo "$page"
    [ "$(field isLastPage)" = true ] && return 0
    start=$(field nextPageStart)
  done
}

# branches and tags of a repository: "<commit id> <name>", sorted
refs() { git ls-remote --refs --heads --tags "$1" | sort; }

source_git() { echo "$SOURCE_URL/scm/$(lower "$SOURCE_PROJECT")/$1.git"; }
target_git() { echo "$TARGET_URL/scm/$(lower "$TARGET_PROJECT")/$1.git"; }

# ---- migration of one repository --------------------------------------------------------
# migrate_repo SOURCE_SLUG TARGET_SLUG [TARGET_NAME]
# returns 0 = OK, 1 = failed, 2 = skipped (already on the target, SYNC=false)
# SYNC=true: update a repository already on the target (branches/tags changed on the source)
migrate_repo() {
  local slug=$1 tslug=$2 tname=${3:-} dir="$WORK/$1.git" name force="" lfs head src tgt src_refs tgt_refs missing
  src=$(source_git "$slug")
  tgt=$(target_git "$tslug")
  LFS_FILES=0

  progress "$slug" "reading the source repository"
  api SOURCE GET "/rest/api/1.0/projects/$SOURCE_PROJECT/repos/$slug"
  [ "$HTTP" = 200 ] || { log "FAILED $slug: cannot read it on the source (HTTP $HTTP $(field message))"; return 1; }
  # same name as on the source (the JSON string is reused as-is, accents/quotes included)
  name=$(printf '%s' "$BODY" | grep -oE '"name" *: *"([^"\\]|\\.)*"' | head -n 1)
  [ -n "$tname" ] && name="\"name\":\"$tname\""

  api TARGET GET "/rest/api/1.0/projects/$TARGET_PROJECT/repos/$tslug"
  if [ "$HTTP" = 404 ]; then
    progress "$slug" "creating $TARGET_PROJECT/$tslug on the target"
    api TARGET POST "/rest/api/1.0/projects/$TARGET_PROJECT/repos" "{$name,\"scmId\":\"git\"}"
    [ "$HTTP" = 201 ] || { log "FAILED $slug: cannot create it on the target (HTTP $HTTP $(field message))"; return 1; }
    [ "$(field slug)" = "$tslug" ] || { log "FAILED $slug: the target created it as '$(field slug)'"; return 1; }
  elif [ "$HTTP" = 200 ]; then
    api TARGET GET "/rest/api/1.0/projects/$TARGET_PROJECT/repos/$tslug/branches?limit=1"
    if [ "$(field size)" != 0 ] && [ "${SYNC:-false}" != true ]; then
      log "SKIPPED $slug: already exists on the target and is not empty (use --sync to update it)"
      return 2
    fi
    [ "${SYNC:-false}" = true ] && force="+"
  else
    log "FAILED $slug: cannot query the target (HTTP $HTTP $(field message))"
    return 1
  fi

  rm -rf "$dir"
  git init -q --bare "$dir" && git -C "$dir" remote add origin "$src" && git -C "$dir" remote add target "$tgt"

  progress "$slug" "downloading branches and tags from the source"
  git -C "$dir" fetch origin '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*' ||
    { log "FAILED $slug: git fetch from the source"; rm -rf "$dir"; return 1; }
  if [ -z "$(git -C "$dir" for-each-ref)" ]; then
    api TARGET PUT "/rest/git-lfs/admin/projects/$TARGET_PROJECT/repos/$tslug/enabled"
    rm -rf "$dir"
    log "OK $slug -> $TARGET_PROJECT/$tslug (empty repository)"
    return 0
  fi

  progress "$slug" "downloading the Git LFS files of all branches and tags"
  git -C "$dir" -c lfs.url="$src/info/lfs" lfs fetch --all origin ||
    { log "FAILED $slug: git lfs fetch from the source"; rm -rf "$dir"; return 1; }
  lfs=$(find "$dir/lfs/objects" -type f 2>/dev/null | wc -l | tr -d ' ')
  LFS_FILES=$lfs

  api TARGET PUT "/rest/git-lfs/admin/projects/$TARGET_PROJECT/repos/$tslug/enabled"
  if [ "$lfs" -gt 0 ]; then
    case "$HTTP" in 2*) ;; *) log "FAILED $slug: cannot enable Git LFS on the target (HTTP $HTTP)"; rm -rf "$dir"; return 1 ;; esac
    progress "$slug" "uploading $lfs Git LFS files to the target"
    git -C "$dir" -c lfs.url="$tgt/info/lfs" lfs push --all target ||
      { log "FAILED $slug: git lfs push to the target"; rm -rf "$dir"; return 1; }
  fi

  progress "$slug" "uploading branches and tags to the target"
  git -C "$dir" push --no-verify target "${force}refs/heads/*:refs/heads/*" "${force}refs/tags/*:refs/tags/*" ||
    { log "FAILED $slug: git push to the target"; rm -rf "$dir"; return 1; }

  head=$(git -C "$dir" ls-remote --symref origin HEAD | awk '/^ref:/ { print $2; exit }')
  [ -n "$head" ] && api TARGET PUT "/rest/api/1.0/projects/$TARGET_PROJECT/repos/$tslug/branches/default" "{\"id\":\"$head\"}"

  progress "$slug" "checking that every branch and tag is identical on the target"
  rm -rf "$dir"
  src_refs=$(refs "$src") && tgt_refs=$(refs "$tgt") || { log "FAILED $slug: cannot list the branches/tags to compare them"; return 1; }
  missing=$(comm -23 <(echo "$src_refs") <(echo "$tgt_refs") | wc -l | tr -d ' ')
  [ "$missing" = 0 ] || { log "FAILED $slug: $missing branches/tags differ between source and target"; return 1; }
  log "OK $slug -> $TARGET_PROJECT/$tslug ($(echo "$src_refs" | grep -c .) branches/tags, $lfs LFS files)"
}
