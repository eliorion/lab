#!/usr/bin/env bash
# shellcheck shell=bash
#
# Pre-flight checks shared by 01-check-connections.sh (full report) and the migration
# scripts (quick pre-flight before touching anything).

CHECK_PASS=0
CHECK_WARN=0
CHECK_FAIL=0
SOURCE_REPOS_FILE=""   # set by check_source_project: slug TAB scmId TAB state TAB name
TARGET_REPOS_FILE=""   # set by check_target_project: slug TAB name

chk_pass() { CHECK_PASS=$((CHECK_PASS + 1)); log_ok "$*"; }
chk_warn() { CHECK_WARN=$((CHECK_WARN + 1)); log_warn "$*"; }
chk_fail() { CHECK_FAIL=$((CHECK_FAIL + 1)); log_error "$*"; }

check_tools() {
  section "Local tools"
  local t v missing=0
  chk_pass "bash $BASH_VERSION"
  for t in curl git grep awk sed base64 sort diff comm paste cut tr split find df mktemp; do
    if ! command -v "$t" >/dev/null 2>&1; then
      chk_fail "'$t' not found in PATH"
      missing=1
    fi
  done
  [ "$missing" = 0 ] && chk_pass "curl and core utilities found ($(curl --version | head -n 1 | awk '{print $1, $2}'))"
  # JSON is parsed with grep -o + awk (no jq needed): make sure they behave as expected
  if [ "$(printf '%s' '{"a":[{"b":"x\"y"}],"c":true}' | json_flatten | tr '\t' '|' | paste -sd' ' -)" = '.a[0].b|s|x"y .c|b|true' ]; then
    chk_pass "JSON parsing with grep + awk works ($(awk --version 2>/dev/null | head -n 1 | cut -d, -f1 || echo awk))"
  else
    chk_fail "JSON parsing with grep -Eo + awk does not work on this machine (grep and awk must support -E/-o)"
  fi

  if command -v git >/dev/null 2>&1; then
    v="$(git --version | awk '{print $3}')"
    if version_ge "$v" 2.31; then
      chk_pass "git $v"
    else
      chk_fail "git $v is too old: >= 2.31 is required (credentials are passed with GIT_CONFIG_COUNT)"
    fi
  fi
  if git lfs version >/dev/null 2>&1; then
    v="$(git lfs version | sed -n 's|^git-lfs/\([0-9.]*\).*|\1|p')"
    if version_ge "$v" 2.10; then
      chk_pass "git-lfs $v"
    else
      chk_warn "git-lfs $v is old, >= 2.10 recommended"
    fi
  elif [ "$MIGRATE_LFS" = true ]; then
    chk_fail "git-lfs is not installed (required because MIGRATE_LFS=true)"
  else
    chk_warn "git-lfs is not installed (MIGRATE_LFS=false: LFS objects will NOT be migrated)"
  fi
}

check_config() {
  section "Configuration ($ENV_FILE)"
  local errors e side url
  errors="$(config_errors)"
  if [ -n "$errors" ]; then
    while IFS= read -r e; do chk_fail "$e"; done <<<"$errors"
    return 1
  fi
  chk_pass "configuration is valid"
  log_info "source : $SOURCE_URL  project $SOURCE_PROJECT_KEY  (auth: $SOURCE_AUTH_TYPE${SOURCE_USERNAME:+, user $SOURCE_USERNAME})"
  log_info "target : $TARGET_URL  project $TARGET_PROJECT_KEY  (auth: $TARGET_AUTH_TYPE${TARGET_USERNAME:+, user $TARGET_USERNAME})"
  log_info "policy : existing repos=$EXISTING_REPO_POLICY, LFS=$MIGRATE_LFS (enable on target: $TARGET_ENABLE_LFS), work dir=$WORK_DIR"
  for side in SOURCE TARGET; do
    url="$(side_var "$side" URL)"
    case "$url" in
      http://*) chk_warn "$(side_label "$side") URL uses plain http://: credentials are sent unencrypted" ;;
    esac
    [ "$(side_var "$side" INSECURE_TLS)" = true ] &&
      chk_warn "$(side_label "$side") TLS certificate verification is DISABLED (${side}_INSECURE_TLS=true)"
  done
  case "$TARGET_URL/" in "$SOURCE_URL"/*)
    [ "$SOURCE_URL" != "$TARGET_URL" ] && chk_warn "TARGET_URL is below SOURCE_URL: git credentials could be mixed up" ;;
  esac
  case "$SOURCE_URL/" in "$TARGET_URL"/*)
    [ "$SOURCE_URL" != "$TARGET_URL" ] && chk_warn "SOURCE_URL is below TARGET_URL: git credentials could be mixed up" ;;
  esac
  [ -n "$REPO_EXCLUDE" ] && log_info "excluded repositories (patterns): $REPO_EXCLUDE"
  return 0
}

# check_server SOURCE|TARGET : reachability, version, authentication
check_server() {
  local side="$1" label url expected version user cfg_user type
  label="$(side_label "$side")"
  url="$(side_var "$side" URL)"
  expected="$(side_var "$side" EXPECTED_VERSION)"
  type="$(side_var "$side" AUTH_TYPE)"
  cfg_user="$(side_var "$side" USERNAME)"
  section "${label^} server: $url"

  api_call "$side" GET "/rest/api/1.0/application-properties"
  case "$API_STATUS" in
    200)
      version="$(jget .version)"
      chk_pass "reachable - $(jget .displayName Bitbucket) $version (build $(jget .buildNumber '?'))"
      printf -v "${side}_VERSION" '%s' "$version"
      if [ -n "$expected" ] && [ "$expected" != "$version" ]; then
        chk_warn "version is $version but ${side}_EXPECTED_VERSION=$expected - is this the right server?"
      fi
      if [ "$type" = bearer ] && ! version_ge "$version" 5.5; then
        chk_fail "Bitbucket $version has no HTTP access tokens (they exist since 5.5): use ${side}_AUTH_TYPE=basic with username/password"
        return 1
      fi
      ;;
    000) chk_fail "cannot reach $url: $(api_err_msg)"; return 1 ;;
    401 | 403) chk_fail "credentials rejected by the $label server: $(api_err_msg)"; return 1 ;;
    *) chk_fail "unexpected answer from $url/rest/api/1.0/application-properties: $(api_err_msg) - check ${side}_URL (context path?)"; return 1 ;;
  esac

  # Bitbucket returns the X-AUSERNAME header on every authenticated request. If it is absent,
  # ask an endpoint that answers 401 to anonymous users.
  user="$(api_header X-AUSERNAME)"
  if [ -z "$user" ]; then
    api_call "$side" GET "/rest/api/1.0/profile/recent/repos?limit=1"
    user="$(api_header X-AUSERNAME)"
    case "$API_STATUS" in
      200) ;;
      401 | 403) chk_fail "authentication failed on the $label server: $(api_err_msg)"; return 1 ;;
      *) chk_warn "could not confirm the identity on the $label server ($(api_err_msg)), the next checks will tell"; return 0 ;;
    esac
  fi
  if [ -n "$user" ]; then chk_pass "authenticated as '$user' ($type)"; else chk_pass "authenticated ($type)"; fi
  if [ -n "$user" ] && [ -n "$cfg_user" ] && [ "$(lower "$user")" != "$(lower "$cfg_user")" ]; then
    chk_warn "${side}_USERNAME=$cfg_user but the server identifies you as '$user'"
  fi
}

check_source_project() {
  local count non_git not_available
  section "Source project $SOURCE_PROJECT_KEY"
  api_call SOURCE GET "/rest/api/1.0/projects/$SOURCE_PROJECT_KEY"
  case "$API_STATUS" in
    200) chk_pass "project found: '$(jget .name)'" ;;
    *) chk_fail "project $SOURCE_PROJECT_KEY not readable on the source: $(api_err_msg)"; return 1 ;;
  esac

  SOURCE_REPOS_FILE="$TMP_DIR/source_repos.tsv"
  if ! fetch_source_repos "$SOURCE_REPOS_FILE"; then
    chk_fail "cannot list the repositories of $SOURCE_PROJECT_KEY"
    return 1
  fi
  count="$(wc -l <"$SOURCE_REPOS_FILE" | tr -d ' ')"
  if [ "$count" -eq 0 ]; then
    chk_warn "no repository found in $SOURCE_PROJECT_KEY (or no read permission on them)"
  else
    chk_pass "$count repositories found"
  fi
  non_git="$(awk -F'\t' '$2 != "git" { print $1 }' "$SOURCE_REPOS_FILE" | paste -sd, -)"
  [ -n "$non_git" ] && chk_warn "non-git repositories (not supported): $non_git"
  not_available="$(awk -F'\t' '$3 != "" && $3 != "AVAILABLE" { print $1 "(" $3 ")" }' "$SOURCE_REPOS_FILE" | paste -sd, -)"
  [ -n "$not_available" ] && chk_warn "repositories not in AVAILABLE state: $not_available"
  return 0
}

check_target_project() {
  local existing collisions n
  section "Target project $TARGET_PROJECT_KEY"
  api_call TARGET GET "/rest/api/1.0/projects/$TARGET_PROJECT_KEY"
  case "$API_STATUS" in
    200) chk_pass "project found: '$(jget .name)'" ;;
    404) chk_fail "project $TARGET_PROJECT_KEY does not exist on the target (or you cannot see it). It must be created by a target admin first."; return 1 ;;
    *) chk_fail "project $TARGET_PROJECT_KEY not readable on the target: $(api_err_msg)"; return 1 ;;
  esac

  # Only project admins (or higher) may list the project permissions.
  api_call TARGET GET "/rest/api/1.0/projects/$TARGET_PROJECT_KEY/permissions/users?limit=1"
  case "$API_STATUS" in
    200) chk_pass "you are PROJECT_ADMIN on $TARGET_PROJECT_KEY (can create repositories and enable LFS)" ;;
    401 | 403) chk_fail "you are not PROJECT_ADMIN on $TARGET_PROJECT_KEY: you need it to create repositories and enable Git LFS"; return 1 ;;
    *) chk_warn "could not verify the project admin permission: $(api_err_msg)" ;;
  esac

  TARGET_REPOS_FILE="$TMP_DIR/target_repos.tsv"
  if ! api_get_paged TARGET "/rest/api/1.0/projects/$TARGET_PROJECT_KEY/repos" slug name >"$TARGET_REPOS_FILE"; then
    chk_fail "cannot list the repositories of the target project"
    return 1
  fi
  existing="$(wc -l <"$TARGET_REPOS_FILE" | tr -d ' ')"
  log_info "$existing repositories already present in the target project"
  if [ -n "$SOURCE_REPOS_FILE" ] && [ -s "$SOURCE_REPOS_FILE" ] && [ "$existing" -gt 0 ]; then
    collisions="$(comm -12 <(cut -f1 "$SOURCE_REPOS_FILE" | sort -u) <(cut -f1 "$TARGET_REPOS_FILE" | sort -u))"
    if [ -n "$collisions" ]; then
      n="$(printf '%s\n' "$collisions" | wc -l | tr -d ' ')"
      chk_warn "$n source repositories already exist on the target (EXISTING_REPO_POLICY=$EXISTING_REPO_POLICY): $(printf '%s\n' "$collisions" | head -n 20 | paste -sd, -)$([ "$n" -gt 20 ] && printf ' ...')"
    else
      chk_pass "no name collision between source and target repositories"
    fi
  fi

  # Project-level branch permissions can reject the initial push of some branches.
  api_call TARGET GET "/rest/branch-permissions/2.0/projects/$TARGET_PROJECT_KEY/restrictions?limit=100"
  if [ "$API_STATUS" = 200 ] && [ "$(jget .size 0)" -gt 0 ]; then
    chk_warn "the target project has branch restrictions that may reject the push: $(jrows .values type matcher.displayId | awk -F'\t' '{ print $1 " on " $2 }' | paste -sd, -)"
  fi
  return 0
}

# check_git_access SIDE PROJECT_KEY SLUG
check_git_access() {
  local side="$1" key="$2" slug="$3" url out heads
  url="$(git_url "$side" "$key" "$slug")"
  if out="$(git ls-remote --heads "$url" 2>&1)"; then
    heads="$(printf '%s\n' "$out" | grep -c 'refs/heads/' || true)"
    chk_pass "git over HTTP(S) works on the $(side_label "$side") ($slug: $heads branches)"
  else
    chk_fail "git ls-remote $url failed: $(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')"
    return 1
  fi
}

# check_lfs_api SIDE PROJECT_KEY SLUG : asks the LFS batch API about a fake object
check_lfs_api() {
  local side="$1" key="$2" slug="$3" body
  body='{"operation":"download","transfers":["basic"],"objects":[{"oid":"0000000000000000000000000000000000000000000000000000000000000000","size":1}]}'
  api_call "$side" POST "/scm/$(lower "$key")/$slug.git/info/lfs/objects/batch" "$body" "application/vnd.git-lfs+json"
  if [ "$API_STATUS" = 200 ]; then
    chk_pass "Git LFS API answers on the $(side_label "$side") ($slug)"
  else
    chk_warn "Git LFS API on the $(side_label "$side") ($slug): $(api_err_msg)"
  fi
}

check_disk() {
  local free
  section "Local disk"
  free="$(free_space_gb "$WORK_DIR")"
  if [ -z "$free" ]; then
    chk_warn "cannot determine the free space of $WORK_DIR"
  elif [ "$free" -lt "$MIN_FREE_SPACE_GB" ]; then
    chk_warn "only ${free} GB free in $WORK_DIR (MIN_FREE_SPACE_GB=$MIN_FREE_SPACE_GB). The biggest repository + its LFS objects must fit."
  else
    chk_pass "${free} GB free in $WORK_DIR"
  fi
}

# Quick pre-flight used by the migration scripts. Dies if something blocking is found.
run_preflight() {
  check_tools
  check_config || die "Invalid configuration - fix $ENV_FILE"
  [ "$CHECK_FAIL" -eq 0 ] || die "Missing local tools"
  setup_git_env
  check_server SOURCE
  check_server TARGET
  [ "$CHECK_FAIL" -eq 0 ] || die "Server checks failed - run scripts/01-check-connections.sh for details"
  check_source_project
  check_target_project
  check_disk
  [ "$CHECK_FAIL" -eq 0 ] || die "Pre-flight checks failed - run scripts/01-check-connections.sh for details"
  log_ok "pre-flight checks passed ($CHECK_WARN warning(s))"
}
