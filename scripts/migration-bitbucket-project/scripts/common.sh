#!/usr/bin/env bash
# Shared settings and functions, loaded by every script.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$ROOT/.env" ] || { echo "Missing $ROOT/.env - copy .env.example to .env and fill it in"; exit 1; }
# (Windows line endings removed, in case .env was edited with Notepad)
# shellcheck source=/dev/null
source <(tr -d '\r' <"$ROOT/.env")

SOURCE_URL="${SOURCE_URL%/}"
TARGET_URL="${TARGET_URL%/}"
TARGET_PROJECT="${TARGET_PROJECT:-$SOURCE_PROJECT}"
# Bitbucket project keys are upper case (ccm_imp -> CCM_IMP)
SOURCE_PROJECT=$(printf '%s' "$SOURCE_PROJECT" | tr '[:lower:]' '[:upper:]')
TARGET_PROJECT=$(printf '%s' "$TARGET_PROJECT" | tr '[:lower:]' '[:upper:]')
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

# git and git-lfs get the logins from a small credential helper reading these variables:
# they send them only when the server asks for them (never twice in the same request).
# Your own saved git credentials (Windows credential manager...) are not used.
export MIG_SOURCE_USER="${SOURCE_USER:-}" MIG_SOURCE_PASS="${SOURCE_TOKEN:-${SOURCE_PASSWORD:-}}"
export MIG_TARGET_USER="${TARGET_USER:-}" MIG_TARGET_PASS="${TARGET_PASSWORD:-}"
export GIT_CONFIG_COUNT=4
export GIT_CONFIG_KEY_0="credential.helper" GIT_CONFIG_VALUE_0=""
# (git asks for a login with the server address only: scheme://host:port, without any path)
export GIT_CONFIG_KEY_1="credential.$(printf '%s' "$SOURCE_URL" | sed -E 's#^([a-z]+://[^/]+).*#\1#').helper"
export GIT_CONFIG_VALUE_1='!f() { if [ "$1" = get ]; then printf "username=%s\npassword=%s\n" "$MIG_SOURCE_USER" "$MIG_SOURCE_PASS"; fi; }; f'
export GIT_CONFIG_KEY_2="credential.$(printf '%s' "$TARGET_URL" | sed -E 's#^([a-z]+://[^/]+).*#\1#').helper"
export GIT_CONFIG_VALUE_2='!f() { if [ "$1" = get ]; then printf "username=%s\npassword=%s\n" "$MIG_TARGET_USER" "$MIG_TARGET_PASS"; fi; }; f'
export GIT_CONFIG_KEY_3="lfs.locksverify" GIT_CONFIG_VALUE_3="false"
export GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never
# Windows (Git Bash) only: trust the certificates of the Windows certificate store
if [ "${WINDOWS_CERT_STORE:-false}" = true ]; then
  export CURL_SSL_BACKEND=schannel GIT_CONFIG_COUNT=5
  export GIT_CONFIG_KEY_4="http.sslBackend" GIT_CONFIG_VALUE_4="schannel"
fi

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
    out=$(curl -sS -H "$auth" -H 'X-Atlassian-Token: no-check' -H 'Content-Type: application/json' -X "$method" -d "$data" -w '\n%{http_code}' "$url$path")
  else
    out=$(curl -sS -H "$auth" -H 'X-Atlassian-Token: no-check' -X "$method" -w '\n%{http_code}' "$url$path")
  fi
  HTTP=${out##*$'\n'}
  BODY=${out%$'\n'*}
  [ -n "$HTTP" ] || HTTP=000   # curl could not connect at all
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

# run COMMAND: git output on screen, or in $GIT_LOG (output/logs/<repo>.log) when several
# repositories are copied at the same time (PARALLEL > 1)
run() { if [ -n "${GIT_LOG:-}" ]; then "$@" >>"$GIT_LOG" 2>&1; else "$@"; fi; }

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

  rm -rf "$dir" 2>/dev/null
  if [ -e "$dir" ]; then
    # files of an old temporary copy are locked (OneDrive, antivirus or a git process still running)
    dir="$WORK/$slug.$(date +%s).git"
    log "[$slug] old temporary copy locked by another program (OneDrive? antivirus?): using ${dir##*/} instead"
  fi
  git init -q --bare "$dir" && git -C "$dir" remote add origin "$src" && git -C "$dir" remote add target "$tgt" ||
    { log "FAILED $slug: cannot create the temporary copy $dir"; return 1; }

  progress "$slug" "downloading branches and tags from the source"
  run git -C "$dir" fetch origin '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*' ||
    { log "FAILED $slug: git fetch from the source${GIT_LOG:+ (details: $GIT_LOG)}"; rm -rf "$dir" 2>/dev/null; return 1; }
  if [ -z "$(git -C "$dir" for-each-ref)" ]; then
    api TARGET PUT "/rest/git-lfs/admin/projects/$TARGET_PROJECT/repos/$tslug/enabled"
    rm -rf "$dir" 2>/dev/null
    log "OK $slug -> $TARGET_PROJECT/$tslug (empty repository)"
    return 0
  fi

  progress "$slug" "downloading the Git LFS files of all branches and tags"
  run git -C "$dir" -c lfs.url="$src/info/lfs" lfs fetch --all origin ||
    { log "FAILED $slug: git lfs fetch from the source${GIT_LOG:+ (details: $GIT_LOG)}"; rm -rf "$dir" 2>/dev/null; return 1; }
  lfs=$(find "$dir/lfs/objects" -type f 2>/dev/null | wc -l | tr -d ' ')
  LFS_FILES=$lfs

  api TARGET PUT "/rest/git-lfs/admin/projects/$TARGET_PROJECT/repos/$tslug/enabled"
  if [ "$lfs" -gt 0 ]; then
    case "$HTTP" in 2*) ;; *) log "FAILED $slug: cannot enable Git LFS on the target (HTTP $HTTP)"; rm -rf "$dir" 2>/dev/null; return 1 ;; esac
    progress "$slug" "uploading $lfs Git LFS files to the target"
    run git -C "$dir" -c lfs.url="$tgt/info/lfs" lfs push --all target ||
      { log "FAILED $slug: git lfs push to the target${GIT_LOG:+ (details: $GIT_LOG)}"; rm -rf "$dir" 2>/dev/null; return 1; }
  fi

  progress "$slug" "uploading branches and tags to the target"
  run git -C "$dir" push --no-verify target "${force}refs/heads/*:refs/heads/*" "${force}refs/tags/*:refs/tags/*" ||
    { log "FAILED $slug: git push to the target${GIT_LOG:+ (details: $GIT_LOG)}"; rm -rf "$dir" 2>/dev/null; return 1; }

  head=$(git -C "$dir" ls-remote --symref origin HEAD | awk '/^ref:/ { print $2; exit }')
  [ -n "$head" ] && api TARGET PUT "/rest/api/1.0/projects/$TARGET_PROJECT/repos/$tslug/branches/default" "{\"id\":\"$head\"}"

  progress "$slug" "checking that every branch and tag is identical on the target"
  rm -rf "$dir" 2>/dev/null
  src_refs=$(refs "$src") && tgt_refs=$(refs "$tgt") || { log "FAILED $slug: cannot list the branches/tags to compare them"; return 1; }
  missing=$(comm -23 <(echo "$src_refs") <(echo "$tgt_refs") | wc -l | tr -d ' ')
  [ "$missing" = 0 ] || { log "FAILED $slug: $missing branches/tags differ between source and target"; return 1; }
  log "OK $slug -> $TARGET_PROJECT/$tslug ($(echo "$src_refs" | grep -c .) branches/tags, $lfs LFS files)"
}
