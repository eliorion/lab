#!/usr/bin/env bash
# shellcheck shell=bash
#
# Shared helpers for the Bitbucket migration scripts:
#   - .env loading (no shell evaluation, passwords with special characters are safe)
#   - logging
#   - REST calls to the SOURCE / TARGET servers (credentials never appear on a command line)
#   - git authentication (injected as HTTP headers through GIT_CONFIG_* environment variables)
#
# This file is sourced by the scripts in scripts/ - it is not meant to be executed directly.

if [ -n "${BBMIG_COMMON_LOADED:-}" ]; then return 0; fi
BBMIG_COMMON_LOADED=1

if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "ERROR: bash >= 4 is required (current: ${BASH_VERSION:-unknown}). On macOS: brew install bash" >&2
  exit 1
fi

BBMIG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BBMIG_SCRIPTS_DIR="$(dirname "$BBMIG_LIB_DIR")"
PROJECT_ROOT="$(dirname "$BBMIG_SCRIPTS_DIR")"
ENV_FILE="${ENV_FILE:-$PROJECT_ROOT/.env}"
ASSUME_YES="${ASSUME_YES:-false}"
MAIN_LOG=""

# --------------------------------------------------------------------------------------
# Logging (to stderr, so functions can return data on stdout; mirrored to MAIN_LOG)
# --------------------------------------------------------------------------------------
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[36m'
  C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""; C_RESET=""
fi

_log() {
  local level="$1" color="$2"; shift 2
  printf '%s %s%-5s%s %s\n' "$(date '+%H:%M:%S')" "$color" "$level" "$C_RESET" "$*" >&2
  if [ -n "$MAIN_LOG" ]; then
    printf '%s %-5s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" >>"$MAIN_LOG"
  fi
}
log_info()  { _log INFO  "$C_BLUE"   "$@"; }
log_ok()    { _log OK    "$C_GREEN"  "$@"; }
log_warn()  { _log WARN  "$C_YELLOW" "$@"; }
log_error() { _log ERROR "$C_RED"    "$@"; }
die()       { log_error "$@"; exit 1; }

section() {
  printf '\n%s== %s ==%s\n' "$C_BOLD" "$*" "$C_RESET" >&2
  if [ -n "$MAIN_LOG" ]; then printf '\n== %s ==\n' "$*" >>"$MAIN_LOG"; fi
}

# --------------------------------------------------------------------------------------
# Small helpers
# --------------------------------------------------------------------------------------
lower() { printf '%s' "${1,,}"; }
upper() { printf '%s' "${1^^}"; }

# side_var SOURCE URL  -> value of $SOURCE_URL
side_var() { local n="${1}_${2}"; printf '%s' "${!n-}"; }

side_label() { if [ "$1" = SOURCE ]; then printf 'source'; else printf 'target'; fi; }

# version_ge 7.21.10 5.5  -> true if $1 >= $2
version_ge() {
  local IFS=.
  local -a a b
  read -r -a a <<<"$1"
  read -r -a b <<<"$2"
  local i x y n=${#a[@]}
  [ "${#b[@]}" -gt "$n" ] && n=${#b[@]}
  for ((i = 0; i < n; i++)); do
    x="${a[i]:-0}"; y="${b[i]:-0}"
    x="${x%%[!0-9]*}"; y="${y%%[!0-9]*}"
    x="${x:-0}"; y="${y:-0}"
    if ((10#$x > 10#$y)); then return 0; fi
    if ((10#$x < 10#$y)); then return 1; fi
  done
  return 0
}

# Absolute path (relative paths are relative to the project root)
abs_path() {
  case "$1" in
    /*) printf '%s' "$1" ;;
    *) printf '%s/%s' "$PROJECT_ROOT" "${1#./}" ;;
  esac
}

is_bool() { [ "$1" = true ] || [ "$1" = false ]; }

csv_field() {
  local s="${1//$'\n'/ }"
  s="${s//\"/\"\"}"
  printf '"%s"' "$s"
}

confirm() {
  [ "$ASSUME_YES" = true ] && return 0
  if [ ! -t 0 ]; then
    log_error "Confirmation needed but stdin is not a terminal: re-run with --yes"
    return 1
  fi
  local answer
  read -r -p "$1 [y/N] " answer
  [[ "$answer" =~ ^([yY]|[yY][eE][sS])$ ]]
}

free_space_gb() {
  df -Pk "$1" 2>/dev/null | awk 'NR==2 { printf "%d", $4 / 1024 / 1024 }'
}

human_size() {
  awk -v b="${1:-0}" 'BEGIN {
    split("B KB MB GB TB", u, " "); i = 1
    while (b >= 1024 && i < 5) { b /= 1024; i++ }
    printf (i == 1 ? "%d %s" : "%.1f %s"), b, u[i]
  }'
}

human_duration() {
  local s="${1:-0}"
  printf '%dh%02dm%02ds' $((s / 3600)) $((s % 3600 / 60)) $((s % 60))
}

# --------------------------------------------------------------------------------------
# .env loading - plain KEY=VALUE parser, no shell evaluation.
# Values may be wrapped in single or double quotes (needed if they contain " #").
# --------------------------------------------------------------------------------------
load_env() {
  local file="$1" line key val n=0 fname
  local re_kv='^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$'
  local re_sq="^'(.*)'[[:space:]]*(#.*)?$"
  local re_dq='^"(.*)"[[:space:]]*(#.*)?$'
  [ -f "$file" ] || die "Configuration file not found: $file (copy .env.example to .env and fill it in)"
  fname="$(basename "$file")"
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in '' | '#'*) continue ;; esac
    line="${line#export }"
    if [[ ! "$line" =~ $re_kv ]]; then
      log_warn "$fname:$n ignored (expected KEY=VALUE)"
      continue
    fi
    key="${BASH_REMATCH[1]}"
    val="${BASH_REMATCH[2]}"
    case "$key" in
      PATH | HOME | IFS | SHELL | USER | PWD | OLDPWD | TMPDIR | ENV_FILE | BASH* | LD_* | GIT_CONFIG* | GIT_DIR | GIT_WORK_TREE)
        log_warn "$fname:$n: refusing to override reserved variable $key"
        continue ;;
    esac
    val="${val#"${val%%[![:space:]]*}"}"
    if [[ "$val" =~ $re_sq ]] || [[ "$val" =~ $re_dq ]]; then
      val="${BASH_REMATCH[1]}"
    else
      val="${val%%[[:space:]]#*}"
      val="${val%"${val##*[![:space:]]}"}"
    fi
    printf -v "$key" '%s' "$val"
  done <"$file"
}

# --------------------------------------------------------------------------------------
# Configuration: defaults, normalisation, validation
# --------------------------------------------------------------------------------------
# Output locations only (used by watch-progress.sh, which needs no credentials)
init_paths() {
  load_env "$ENV_FILE"
  : "${OUTPUT_DIR:=output}"
  OUTPUT_DIR="$(abs_path "$OUTPUT_DIR")"
  : "${WORK_DIR:=$OUTPUT_DIR/work}" "${LOG_DIR:=$OUTPUT_DIR/logs}" "${STATE_DIR:=$OUTPUT_DIR/state}"
  WORK_DIR="$(abs_path "$WORK_DIR")"
  LOG_DIR="$(abs_path "$LOG_DIR")"
  STATE_DIR="$(abs_path "$STATE_DIR")"
  STATUS_FILE="$OUTPUT_DIR/STATUS.txt"
}

init_config() {
  init_paths

  : "${SOURCE_URL:=}" "${SOURCE_PROJECT_KEY:=}" "${SOURCE_AUTH_TYPE:=bearer}"
  : "${SOURCE_USERNAME:=}" "${SOURCE_PASSWORD:=}" "${SOURCE_TOKEN:=}"
  : "${SOURCE_EXPECTED_VERSION:=}" "${SOURCE_CA_BUNDLE:=}" "${SOURCE_INSECURE_TLS:=false}"
  : "${TARGET_URL:=}" "${TARGET_PROJECT_KEY:=}" "${TARGET_AUTH_TYPE:=basic}"
  : "${TARGET_USERNAME:=}" "${TARGET_PASSWORD:=}" "${TARGET_TOKEN:=}"
  : "${TARGET_EXPECTED_VERSION:=}" "${TARGET_CA_BUNDLE:=}" "${TARGET_INSECURE_TLS:=false}"

  : "${KEEP_WORKDIR:=false}" "${EXISTING_REPO_POLICY:=skip}" "${SYNC_PRUNE:=false}"
  : "${MIGRATE_LFS:=true}" "${TARGET_ENABLE_LFS:=auto}" "${LFS_ALLOW_MISSING:=false}" "${VERIFY_LFS:=true}"
  : "${COPY_DEFAULT_BRANCH:=true}" "${COPY_FORKABLE:=true}" "${COPY_PUBLIC:=false}"
  : "${REPO_EXCLUDE:=}" "${TEST_REPO_SLUG:=}" "${TEST_TARGET_SUFFIX:=-migration-test}"
  : "${LFS_CONCURRENT_TRANSFERS:=4}" "${GIT_HTTP_POST_BUFFER:=}" "${RETRY_COUNT:=2}" "${MAX_CONSECUTIVE_FAILURES:=5}"
  : "${MIN_FREE_SPACE_GB:=20}" "${CURL_CONNECT_TIMEOUT:=15}" "${CURL_TIMEOUT:=120}" "${PAGE_LIMIT:=100}"

  local side v
  for side in SOURCE TARGET; do
    v="$(side_var "$side" URL)"
    while [ "${v%/}" != "$v" ]; do v="${v%/}"; done
    printf -v "${side}_URL" '%s' "$v"
    [ "$side" = TARGET ] && [ -z "$TARGET_PROJECT_KEY" ] && TARGET_PROJECT_KEY="$SOURCE_PROJECT_KEY"
    printf -v "${side}_PROJECT_KEY" '%s' "$(upper "$(side_var "$side" PROJECT_KEY)")"
    printf -v "${side}_AUTH_TYPE" '%s' "$(lower "$(side_var "$side" AUTH_TYPE)")"
    v="$(side_var "$side" CA_BUNDLE)"
    [ -n "$v" ] && printf -v "${side}_CA_BUNDLE" '%s' "$(abs_path "$v")"
  done
  EXISTING_REPO_POLICY="$(lower "$EXISTING_REPO_POLICY")"
  TARGET_ENABLE_LFS="$(lower "$TARGET_ENABLE_LFS")"
  KEEP_WORKDIR="$(lower "$KEEP_WORKDIR")"

  mkdir -p "$OUTPUT_DIR" "$WORK_DIR" "$LOG_DIR" "$STATE_DIR" || die "Cannot create the output directories in $OUTPUT_DIR"

  TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bbmig.XXXXXXXX")" || die "mktemp failed"
  chmod 700 "$TMP_DIR"
  trap 'bbmig_on_exit' EXIT
  trap 'log_warn "Interrupted"; exit 130' INT TERM

  build_curl_config SOURCE
  build_curl_config TARGET
}

bbmig_on_exit() {
  local rc=$?
  if declare -F on_exit_hook >/dev/null; then on_exit_hook || true; fi
  if [ "$STATUS_ACTIVE" = true ] && [ "$STATUS_STATE" = RUNNING ]; then
    case "$rc" in 0) status_end FINISHED ;; 130) status_end INTERRUPTED ;; *) status_end FAILED ;; esac
  fi
  [ -n "${TMP_DIR:-}" ] && rm -rf "$TMP_DIR"
  return $rc
}

# Prints one line per configuration problem (empty output = valid configuration)
config_errors() {
  local side label type v
  for side in SOURCE TARGET; do
    label="$(side_label "$side")"
    v="$(side_var "$side" URL)"
    if [ -z "$v" ]; then
      echo "${side}_URL is empty"
    elif [[ ! "$v" =~ ^https?://[^/]+ ]]; then
      echo "${side}_URL must start with https:// or http:// (got '$v')"
    fi
    [ -n "$(side_var "$side" PROJECT_KEY)" ] || echo "${side}_PROJECT_KEY is empty"
    type="$(side_var "$side" AUTH_TYPE)"
    case "$type" in
      bearer) [ -n "$(side_var "$side" TOKEN)" ] || echo "${side}_AUTH_TYPE=bearer but ${side}_TOKEN is empty" ;;
      basic)
        [ -n "$(side_var "$side" USERNAME)" ] || echo "${side}_AUTH_TYPE=basic but ${side}_USERNAME is empty"
        [ -n "$(side_var "$side" PASSWORD)$(side_var "$side" TOKEN)" ] ||
          echo "${side}_AUTH_TYPE=basic but ${side}_PASSWORD is empty" ;;
      *) echo "${side}_AUTH_TYPE must be 'bearer' or 'basic' (got '$type') for the $label server" ;;
    esac
    v="$(side_var "$side" CA_BUNDLE)"
    [ -z "$v" ] || [ -r "$v" ] || echo "${side}_CA_BUNDLE file not readable: $v"
    is_bool "$(side_var "$side" INSECURE_TLS)" || echo "${side}_INSECURE_TLS must be true or false"
  done
  case "$EXISTING_REPO_POLICY" in skip | sync | fail) ;; *) echo "EXISTING_REPO_POLICY must be skip, sync or fail" ;; esac
  case "$TARGET_ENABLE_LFS" in auto | always | never) ;; *) echo "TARGET_ENABLE_LFS must be auto, always or never" ;; esac
  case "$KEEP_WORKDIR" in true | false | on-failure) ;; *) echo "KEEP_WORKDIR must be true, false or on-failure" ;; esac
  for v in SYNC_PRUNE MIGRATE_LFS LFS_ALLOW_MISSING VERIFY_LFS COPY_DEFAULT_BRANCH COPY_FORKABLE COPY_PUBLIC; do
    is_bool "${!v}" || echo "$v must be true or false (got '${!v}')"
  done
  for v in LFS_CONCURRENT_TRANSFERS RETRY_COUNT MAX_CONSECUTIVE_FAILURES MIN_FREE_SPACE_GB CURL_CONNECT_TIMEOUT CURL_TIMEOUT PAGE_LIMIT; do
    [[ "${!v}" =~ ^[0-9]+$ ]] || echo "$v must be a number (got '${!v}')"
  done
  [ -z "$GIT_HTTP_POST_BUFFER" ] || [[ "$GIT_HTTP_POST_BUFFER" =~ ^[0-9]+[kmgKMG]?$ ]] ||
    echo "GIT_HTTP_POST_BUFFER must be a size like 524288000 or 500m"
  if [ "$SOURCE_URL" = "$TARGET_URL" ] && [ "$SOURCE_PROJECT_KEY" = "$TARGET_PROJECT_KEY" ]; then
    echo "SOURCE and TARGET point to the same server and project"
  fi
}

# --------------------------------------------------------------------------------------
# Authentication
# --------------------------------------------------------------------------------------
auth_header() {
  local side="$1" type secret
  type="$(side_var "$side" AUTH_TYPE)"
  if [ "$type" = bearer ]; then
    printf 'Authorization: Bearer %s' "$(side_var "$side" TOKEN)"
  else
    secret="$(side_var "$side" PASSWORD)"
    [ -n "$secret" ] || secret="$(side_var "$side" TOKEN)"
    printf 'Authorization: Basic %s' \
      "$(printf '%s:%s' "$(side_var "$side" USERNAME)" "$secret" | base64 | tr -d '\n')"
  fi
}

_curl_quote() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '"%s"' "$s"
}

# curl reads the Authorization header from a private config file (never from argv)
build_curl_config() {
  local side="$1" f ca insecure
  f="$TMP_DIR/curl_${side}.cfg"
  ca="$(side_var "$side" CA_BUNDLE)"
  insecure="$(side_var "$side" INSECURE_TLS)"
  (
    umask 077
    {
      printf 'header = %s\n' "$(_curl_quote "$(auth_header "$side")")"
      printf 'connect-timeout = %s\n' "$CURL_CONNECT_TIMEOUT"
      printf 'max-time = %s\n' "$CURL_TIMEOUT"
      printf 'user-agent = "bitbucket-migration-scripts"\n'
      if [ -n "$ca" ]; then printf 'cacert = %s\n' "$(_curl_quote "$ca")"; fi
      if [ "$insecure" = true ]; then printf 'insecure\n'; fi
    } >"$f"
  )
}

# git and git-lfs get the credentials as http.<url>.extraHeader through GIT_CONFIG_COUNT
# environment variables (git >= 2.31): nothing is written to disk or visible in `ps`.
# The user's own credential helpers are disabled for these commands.
setup_git_env() {
  local side url ca i=0
  _gitcfg() {
    export "GIT_CONFIG_KEY_$i=$1"
    export "GIT_CONFIG_VALUE_$i=$2"
    i=$((i + 1))
  }
  for side in SOURCE TARGET; do
    url="$(side_var "$side" URL)"
    _gitcfg "http.${url}/.extraHeader" "$(auth_header "$side")"
    ca="$(side_var "$side" CA_BUNDLE)"
    if [ -n "$ca" ]; then _gitcfg "http.${url}/.sslCAInfo" "$ca"; fi
    if [ "$(side_var "$side" INSECURE_TLS)" = true ]; then _gitcfg "http.${url}/.sslVerify" "false"; fi
  done
  _gitcfg credential.helper ""
  _gitcfg lfs.locksverify false
  _gitcfg lfs.concurrenttransfers "$LFS_CONCURRENT_TRANSFERS"
  _gitcfg lfs.fetchinclude ""
  _gitcfg lfs.fetchexclude ""
  _gitcfg core.askPass ""
  if [ -n "$GIT_HTTP_POST_BUFFER" ]; then _gitcfg http.postBuffer "$GIT_HTTP_POST_BUFFER"; fi
  export GIT_CONFIG_COUNT=$i
  export GIT_TERMINAL_PROMPT=0
  export GIT_LFS_SKIP_SMUDGE=1
  unset GIT_ASKPASS SSH_ASKPASS
  unset -f _gitcfg
}

git_url() { # git_url SIDE PROJECT_KEY SLUG
  printf '%s/scm/%s/%s.git' "$(side_var "$1" URL)" "$(lower "$2")" "$3"
}

# --------------------------------------------------------------------------------------
# JSON without jq: grep splits the JSON into tokens, lib/json.awk flattens them into
#   <path> TAB <kind> TAB <value>      e.g.   .values[0].slug<TAB>s<TAB>my-repo
# --------------------------------------------------------------------------------------
JSON_TOKEN_RE='"([^"\\]|\\.)*"|-?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?|true|false|null|[][{}:,]'

json_flatten() { # JSON on stdin -> flattened lines on stdout
  LC_ALL=C grep -Eo "$JSON_TOKEN_RE" | LC_ALL=C awk -f "$BBMIG_LIB_DIR/json.awk"
}

# json_str VALUE -> VALUE as a quoted JSON string
json_str() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  printf '"%s"' "$s"
}

# jget PATH [DEFAULT] -> value at PATH in the last API response (DEFAULT if absent or null)
jget() {
  local v
  if v="$(printf '%s\n' "$API_FLAT" | awk -F'\t' -v p="$1" '
      $1 == p && $2 != "z" { v = $3; f = 1 }
      END { if (f) print v; else exit 1 }')"; then
    printf '%s' "$v"
  else
    printf '%s' "${2-}"
  fi
}

# jrows ARRAY_PATH FIELD... -> one TAB separated line per element of the array
#   jrows .values slug name project.key
jrows() {
  local pre="$1"; shift
  printf '%s\n' "$API_FLAT" | awk -F'\t' -v pre="${pre}[" -v fl="$*" '
    BEGIN { nf = split(fl, F, " "); for (i = 1; i <= nf; i++) want[F[i]] = i }
    index($1, pre) == 1 {
      rest = substr($1, length(pre) + 1); j = index(rest, "]")
      n = substr(rest, 1, j - 1); f = substr(rest, j + 1)
      if (substr(f, 1, 1) == ".") f = substr(f, 2)
      if (!(n in seen)) { seen[n] = 1; order[++cnt] = n }
      if (f in want) val[n, want[f]] = ($2 == "z" ? "" : $3)
    }
    END {
      for (c = 1; c <= cnt; c++) {
        line = ""
        for (i = 1; i <= nf; i++) line = line (i > 1 ? "\t" : "") val[order[c], i]
        print line
      }
    }'
}

# --------------------------------------------------------------------------------------
# REST calls
#   api_call SIDE METHOD PATH [BODY] [CONTENT_TYPE]
#   Sets API_STATUS (HTTP code, 000 = network/TLS error), API_BODY, API_HEADERS, API_ERROR,
#   API_FLAT (flattened JSON body, see jget / jrows)
#   GET requests are retried on network errors / 5xx / 429.
# --------------------------------------------------------------------------------------
API_STATUS=""; API_BODY=""; API_HEADERS=""; API_ERROR=""; API_FLAT=""

api_call() {
  local side="$1" method="$2" path="$3" body="${4-}" ctype="${5:-application/json}"
  local base cfg bodyf hdrf errf attempt=0
  # Safety lock: the SOURCE server is only ever read. The only non-GET request allowed is
  # the LFS batch API with the "download" operation (it only asks which objects exist).
  if [ "$side" = SOURCE ]; then
    case "$method" in
      GET | HEAD) ;;
      POST)
        case "$path" in */info/lfs/objects/batch) ;; *) die "SAFETY: refused $method $path on the SOURCE server (read-only)" ;; esac
        case "$body" in *'"operation":"download"'*) ;; *) die "SAFETY: refused LFS upload request on the SOURCE server (read-only)" ;; esac
        ;;
      *) die "SAFETY: refused $method $path on the SOURCE server (read-only)" ;;
    esac
  fi
  base="$(side_var "$side" URL)"
  cfg="$TMP_DIR/curl_${side}.cfg"
  bodyf="$(mktemp "$TMP_DIR/body.XXXXXX")"
  hdrf="$(mktemp "$TMP_DIR/hdr.XXXXXX")"
  errf="$(mktemp "$TMP_DIR/err.XXXXXX")"
  local -a args=(-sS -K "$cfg" -X "$method" -o "$bodyf" -D "$hdrf" -w '%{http_code}' -H "Accept: $ctype")
  case "$method" in GET | HEAD) ;; *) args+=(-H 'X-Atlassian-Token: no-check') ;; esac
  if [ -n "$body" ]; then args+=(-H "Content-Type: $ctype" --data-binary "$body"); fi
  while :; do
    attempt=$((attempt + 1))
    API_STATUS="$(curl "${args[@]}" "$base$path" 2>"$errf")"
    [ -n "$API_STATUS" ] || API_STATUS=000
    if [ "$method" = GET ] && [ "$attempt" -le "$RETRY_COUNT" ] &&
      { [ "$API_STATUS" = 000 ] || [ "$API_STATUS" -ge 500 ] || [ "$API_STATUS" = 429 ]; }; then
      sleep $((attempt * 3))
      continue
    fi
    break
  done
  API_BODY="$(cat "$bodyf")"
  API_HEADERS="$(tr -d '\r' <"$hdrf")"
  API_ERROR="$(head -c 500 "$errf")"
  API_FLAT=""
  case "$(head -c 64 "$bodyf" | tr -d ' \t\r\n' | cut -c1)" in
    '{' | '[') API_FLAT="$(json_flatten <"$bodyf")" ;;
  esac
  rm -f "$bodyf" "$hdrf" "$errf"
  return 0
}

api_header() { # value of a response header of the last api_call (last occurrence)
  printf '%s\n' "$API_HEADERS" | grep -i "^$1:" | tail -n 1 | sed 's/^[^:]*:[[:space:]]*//'
}

api_err_msg() { # human readable error for the last api_call
  local m reason
  if [ "$API_STATUS" = 000 ]; then
    m="network/TLS error: ${API_ERROR:-unknown}"
  else
    m="$(jrows .errors message | paste -sd';' - | sed 's/;/; /g')"
    [ -n "$m" ] || m="$(printf '%s' "$API_BODY" | sed 's/<[^>]*>//g' | tr -s '\n\t ' ' ' | head -c 200)"
    m="HTTP $API_STATUS${m:+ - $m}"
  fi
  reason="$(api_header X-Authentication-Denied-Reason)"
  if [ -n "$reason" ]; then
    m="$m [auth denied: $reason]"
    case "$reason" in *CAPTCHA*) m="$m -> log in once through the web UI to clear the CAPTCHA" ;; esac
  fi
  printf '%s' "$m"
}

# api_get_paged SIDE PATH FIELD... -> one TAB separated line per element of .values
api_get_paged() {
  local side="$1" path="$2" start=0 sep="?" next
  shift 2
  case "$path" in *\?*) sep="&" ;; esac
  while :; do
    api_call "$side" GET "${path}${sep}start=${start}&limit=${PAGE_LIMIT}"
    if [ "$API_STATUS" != 200 ]; then
      log_error "GET $path ($(side_label "$side")): $(api_err_msg)"
      return 1
    fi
    jrows .values "$@"
    [ "$(jget .isLastPage true)" = true ] && break
    next="$(jget .nextPageStart)"
    [ -n "$next" ] || break
    start="$next"
  done
}

# --------------------------------------------------------------------------------------
# Repository list helpers
# --------------------------------------------------------------------------------------
# Writes the source repositories to the given file: slug TAB scmId TAB state TAB name
fetch_source_repos() {
  api_get_paged SOURCE "/rest/api/1.0/projects/${SOURCE_PROJECT_KEY}/repos" slug scmId state name >"$1"
}

# is_excluded SLUG -> true if SLUG matches one of the comma separated REPO_EXCLUDE patterns
is_excluded() {
  local slug="$1" pat
  local -a pats
  IFS=',' read -r -a pats <<<"$REPO_EXCLUDE"
  for pat in "${pats[@]+"${pats[@]}"}"; do
    pat="${pat// /}"
    [ -n "$pat" ] || continue
    # shellcheck disable=SC2053
    [[ "$slug" == $pat ]] && return 0
  done
  return 1
}

state_file() { printf '%s/%s_to_%s.done' "$STATE_DIR" "$SOURCE_PROJECT_KEY" "$TARGET_PROJECT_KEY"; }

# Target slug recorded for a source slug in the state file (empty if never migrated)
state_target_slug() {
  local f; f="$(state_file)"
  [ -f "$f" ] || return 0
  awk -F'\t' -v s="$1" '$1 == s { t = $2 } END { if (t != "") print t }' "$f"
}

state_record() { # state_record SOURCE_SLUG TARGET_SLUG
  local f; f="$(state_file)"
  printf '%s\t%s\t%s\n' "$1" "$2" "$(date '+%Y-%m-%dT%H:%M:%S')" >>"$f"
}

# --------------------------------------------------------------------------------------
# Live status: output/STATUS.txt is rewritten at every step (see scripts/watch-progress.sh)
# --------------------------------------------------------------------------------------
STATUS_ACTIVE=false; STATUS_STATE=""; STATUS_TITLE=""; STATUS_START_EPOCH=0
STATUS_TOTAL=0; STATUS_INDEX=0; STATUS_OK=0; STATUS_SKIP=0; STATUS_FAIL=0
STATUS_REPO=""; STATUS_REPO_SINCE=""; STATUS_STEP=""; STATUS_REPO_LOG=""; STATUS_LFS_PROGRESS=""; STATUS_REPORT=""

status_begin() { # status_begin TITLE TOTAL REPORT_FILE
  STATUS_ACTIVE=true; STATUS_STATE=RUNNING; STATUS_TITLE="$1"; STATUS_TOTAL="$2"; STATUS_REPORT="${3-}"
  STATUS_START_EPOCH="$(date +%s)"
  status_write
}

status_repo() { # status_repo INDEX SLUG REPO_LOG LFS_PROGRESS_FILE
  STATUS_INDEX="$1"; STATUS_REPO="$2"; STATUS_REPO_LOG="${3-}"; STATUS_LFS_PROGRESS="${4-}"
  STATUS_REPO_SINCE="$(date '+%H:%M:%S')"; STATUS_STEP="starting"
  status_write
}

status_step() { [ "$STATUS_ACTIVE" = true ] || return 0; STATUS_STEP="$*"; status_write; }

status_end() {
  STATUS_STATE="$1"; STATUS_REPO=""; STATUS_STEP=""
  status_write
}

status_write() {
  [ "$STATUS_ACTIVE" = true ] || return 0
  local now elapsed done_n pct eta="" tmp
  now="$(date +%s)"; elapsed=$((now - STATUS_START_EPOCH))
  done_n=$((STATUS_OK + STATUS_SKIP + STATUS_FAIL))
  pct=0; [ "$STATUS_TOTAL" -gt 0 ] && pct=$((done_n * 100 / STATUS_TOTAL))
  if [ "$STATUS_STATE" = RUNNING ] && [ "$done_n" -gt 0 ] && [ "$done_n" -lt "$STATUS_TOTAL" ]; then
    eta="   ETA ~$(human_duration $((elapsed * (STATUS_TOTAL - done_n) / done_n)))"
  fi
  tmp="$STATUS_FILE.tmp.$$"
  {
    echo "Bitbucket migration - live status       (live view: scripts/watch-progress.sh)"
    echo "updated      : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "state        : $STATUS_STATE"
    echo "run          : $STATUS_TITLE   [${RUN_ID:-}]"
    echo "source       : $SOURCE_URL  project $SOURCE_PROJECT_KEY"
    echo "target       : $TARGET_URL  project $TARGET_PROJECT_KEY"
    echo "progress     : $done_n/$STATUS_TOTAL repositories done ($pct%)   OK $STATUS_OK   skipped $STATUS_SKIP   failed $STATUS_FAIL"
    echo "elapsed      : $(human_duration "$elapsed")$eta"
    if [ -n "$STATUS_REPO" ]; then
      echo "current repo : [$STATUS_INDEX/$STATUS_TOTAL] $STATUS_REPO   (since $STATUS_REPO_SINCE)"
      echo "current step : $STATUS_STEP"
    fi
    if [ -n "$STATUS_REPO" ]; then
      echo "repo log     : $STATUS_REPO_LOG"
      echo "lfs progress : $STATUS_LFS_PROGRESS"
    fi
    echo "report       : $STATUS_REPORT"
    echo "run logs     : ${RUN_LOG_DIR:-}"
  } >"$tmp" 2>/dev/null && mv -f "$tmp" "$STATUS_FILE" 2>/dev/null
  return 0
}

start_run() { # start_run NAME -> creates logs/<timestamp>-NAME/
  local n=1
  RUN_ID="$(date '+%Y%m%d-%H%M%S')-$1"
  while [ -e "$LOG_DIR/$RUN_ID" ]; do n=$((n + 1)); RUN_ID="$(date '+%Y%m%d-%H%M%S')-$1-$n"; done
  RUN_LOG_DIR="$LOG_DIR/$RUN_ID"
  mkdir -p "$RUN_LOG_DIR/repos"
  MAIN_LOG="$RUN_LOG_DIR/main.log"
  : >"$MAIN_LOG"
}
