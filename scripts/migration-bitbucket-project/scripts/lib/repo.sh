#!/usr/bin/env bash
# shellcheck shell=bash
#
# Migration of ONE repository from the source to the target server, used by
#   02-test-single-repo.sh and 03-migrate-project.sh
#
#  1. read the source repository (name, settings, LFS flag)
#  2. create it in the target project (or reuse it, depending on EXISTING_REPO_POLICY)
#  3. fetch all branches + tags into a local bare repository (pull-request refs are ignored:
#     the target would reject them)
#  4. fetch ALL Git LFS objects of all branches/tags, enable LFS on the target, upload them
#  5. push all branches + tags, set the default branch
#  6. verify: target refs == fetched refs, every LFS object present on the target

# Results of the last migrate_repo call
R_SOURCE_SLUG=""; R_TARGET_SLUG=""; R_STATUS=""; R_MESSAGE=""
R_BRANCHES=0; R_TAGS=0; R_LFS_OBJECTS=0; R_LFS_BYTES=0; R_DURATION=0; R_DEFAULT_BRANCH=""
REPO_WORK=""; REPO_LOG=""
REPORT_CSV=""   # when set, migrate_repo appends one CSV row per repository

report_header() {
  printf 'source_slug,target_slug,status,branches,tags,lfs_objects,lfs_bytes,default_branch,duration_s,message\n'
}

report_row() {
  [ -n "$REPORT_CSV" ] || return 0
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$(csv_field "$R_SOURCE_SLUG")" "$(csv_field "$R_TARGET_SLUG")" "$R_STATUS" \
    "$R_BRANCHES" "$R_TAGS" "$R_LFS_OBJECTS" "$R_LFS_BYTES" "$(csv_field "$R_DEFAULT_BRANCH")" \
    "$R_DURATION" "$(csv_field "$R_MESSAGE")" >>"$REPORT_CSV"
}

# Run a command, its output goes to the repository log
run_logged() {
  printf '\n$ %s\n' "$*" >>"$REPO_LOG"
  "$@" >>"$REPO_LOG" 2>&1
}

# "git -C dir -c k=v lfs fetch --all origin" -> "git lfs fetch"
cmd_label() {
  local -a words=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -C | -c) shift ;;
      *) words+=("$1") ;;
    esac
    shift
  done
  printf '%s' "${words[*]:0:3}"
}

# Run a command with retries (network operations). Permanent errors (missing object,
# authentication, permission, hook rejection) are not retried.
run_retry() {
  local attempt=1 before
  while :; do
    before="$(wc -c <"$REPO_LOG" | tr -d ' ')"
    run_logged "$@" && return 0
    [ "$attempt" -gt "$RETRY_COUNT" ] && return 1
    if tail -c +"$((before + 1))" "$REPO_LOG" |
      grep -qiE 'does not exist on the server|authentication failed|not authorized|permission denied|HTTP 40[13]|\[remote rejected\]|pre-receive hook declined'; then
      return 1
    fi
    log_warn "[$R_SOURCE_SLUG] '$(cmd_label "$@")' failed, retrying ($attempt/$RETRY_COUNT)"
    sleep $((attempt * 5))
    attempt=$((attempt + 1))
  done
}

log_tail() { # last meaningful lines of the repository log (progress meters removed), for error messages
  tail -c 20000 "$REPO_LOG" 2>/dev/null | tr '\r' '\n' |
    grep -vE '^(remote: )?(Enumerating|Counting|Compressing|Receiving|Resolving|Writing|Total|Delta|Checking) |LFS objects: +[0-9]+%|^[[:space:]]*$' |
    tail -n "${1:-5}" | tr '\n' ' ' | head -c 400
}

# "oid size" of every LFS object stored in a local repository
list_local_lfs_objects() {
  local dir="$1/lfs/objects" f oid
  [ -d "$dir" ] || return 0
  find "$dir" -type f | while IFS= read -r f; do
    oid="${f##*/}"
    [[ ${#oid} -eq 64 && "$oid" =~ ^[0-9a-f]+$ ]] || continue
    printf '%s %s\n' "$oid" "$(wc -c <"$f" | tr -d ' ')"
  done | sort
}

# "oid size" of every Git LFS pointer found in the whole history of all local refs
# (pure git: works whatever the git-lfs version)
list_lfs_pointers() {
  local d="$1"
  git -C "$d" rev-list --objects --all | cut -d' ' -f1 |
    git -C "$d" cat-file --batch-check='%(objecttype) %(objectname) %(objectsize)' |
    awk '$1 == "blob" && $3 < 1024 { print $2 }' |
    git -C "$d" cat-file --batch |
    LC_ALL=C awk '
      /^[0-9a-f]+ blob [0-9]+$/ && (length($1) == 40 || length($1) == 64) { first = 1; ptr = 0; oid = ""; next }
      first { first = 0; ptr = ($0 ~ /^version https:\/\/(git-lfs\.github\.com|hawser\.github\.com)\/spec\//); next }
      ptr && /^oid sha256:[0-9a-f]+$/ && length($0) == 75 { oid = substr($0, 12) }
      ptr && /^size [0-9]+$/ && oid != "" { print oid, substr($0, 6); oid = "" }' |
    sort -u
}

# lfs_missing_on SIDE PROJECT_KEY SLUG OBJECTS_FILE [MISSING_FILE]
# Asks the LFS batch API (download operation, no data transferred) whether every object
# exists. Prints the number of missing objects ("oid size" lines written to MISSING_FILE);
# returns 1 if the API could not be queried.
lfs_missing_on() {
  local side="$1" key="$2" slug="$3" objects="$4" missing_file="${5:-/dev/null}" chunk body missing=0 n path
  path="/scm/$(lower "$key")/$slug.git/info/lfs/objects/batch"
  local chunks="$TMP_DIR/lfs_chunk_$$_"
  rm -f "$chunks"*
  : >"$missing_file"
  split -l 100 "$objects" "$chunks"
  for chunk in "$chunks"*; do
    [ -f "$chunk" ] || continue
    body="$(awk 'NF == 2 { printf "%s{\"oid\":\"%s\",\"size\":%s}", (n++ ? "," : ""), $1, $2 }
                 BEGIN { printf "{\"operation\":\"download\",\"transfers\":[\"basic\"],\"objects\":[" }
                 END { printf "]}" }' "$chunk")"
    api_call "$side" POST "$path" "$body" "application/vnd.git-lfs+json"
    if [ "$API_STATUS" != 200 ]; then
      log_error "[$R_SOURCE_SLUG] LFS batch API on the $(side_label "$side"): $(api_err_msg)"
      rm -f "$chunks"*
      return 1
    fi
    # an object is missing when the server returns an error or no download action for it
    jrows .objects oid size error.code error.message actions.download.href |
      awk -F'\t' '$3 != "" || $5 == ""' >"$chunk.missing"
    n="$(wc -l <"$chunk.missing" | tr -d ' ')"
    awk -F'\t' -v w="$(side_label "$side")" '{ print "missing LFS object on the " w ": " $1 " (" $2 " bytes) " $4 }' "$chunk.missing" >>"$REPO_LOG"
    awk -F'\t' '{ print $1, $2 }' "$chunk.missing" >>"$missing_file"
    missing=$((missing + n))
  done
  rm -f "$chunks"*
  printf '%s' "$missing"
}

# Refs (heads + tags) of a remote, "sha refname" sorted
remote_refs() {
  git -C "$1" ls-remote --refs "$2" 2>>"$REPO_LOG" |
    awk '$2 ~ /^refs\/(heads|tags)\// { print $1, $2 }' | sort
}

local_refs() {
  git -C "$1" for-each-ref --format='%(objectname) %(refname)' refs/heads refs/tags | sort
}

# Approximation of the slug Bitbucket derives from a repository name
guess_slug() {
  lower "$1" | sed -e 's/[[:space:]]\{1,\}/-/g' -e 's/[^a-z0-9._-]//g'
}

target_enable_lfs() {
  local slug="$1"
  api_call TARGET PUT "/rest/git-lfs/admin/projects/$TARGET_PROJECT_KEY/repos/$slug/enabled"
  case "$API_STATUS" in 200 | 201 | 204) return 0 ;; esac
  return 1
}

target_delete_repo() { # target_delete_repo SLUG  (waits until it is really gone)
  local slug="$1"
  api_call TARGET DELETE "/rest/api/1.0/projects/$TARGET_PROJECT_KEY/repos/$slug"
  case "$API_STATUS" in
    202 | 204) ;;
    404) return 0 ;;
    *) log_error "cannot delete $TARGET_PROJECT_KEY/$slug on the target: $(api_err_msg)"; return 1 ;;
  esac
  for _ in $(seq 1 30); do
    api_call TARGET GET "/rest/api/1.0/projects/$TARGET_PROJECT_KEY/repos/$slug"
    [ "$API_STATUS" = 404 ] && return 0
    sleep 2
  done
  log_warn "$TARGET_PROJECT_KEY/$slug is still visible on the target after 60s"
  return 0
}

# migrate_repo SOURCE_SLUG [TARGET_NAME]
# Returns 0 = OK, 1 = FAILED, 2 = SKIPPED ; details in R_* variables
migrate_repo() {
  local src_slug="$1" tgt_name="${2-}" rc start=$SECONDS
  R_SOURCE_SLUG="$src_slug"; R_TARGET_SLUG=""; R_STATUS=FAILED; R_MESSAGE=""
  R_BRANCHES=0; R_TAGS=0; R_LFS_OBJECTS=0; R_LFS_BYTES=0; R_DEFAULT_BRANCH=""
  REPO_WORK="$WORK_DIR/$SOURCE_PROJECT_KEY/$src_slug.git"
  REPO_LOG="${RUN_LOG_DIR:-$LOG_DIR}/repos/$src_slug.log"
  mkdir -p "$(dirname "$REPO_LOG")" "$(dirname "$REPO_WORK")"
  # git-lfs writes one line per transferred file there (shown live by watch-progress.sh)
  export GIT_LFS_PROGRESS="${REPO_LOG%.log}.lfs-progress"
  : >"$GIT_LFS_PROGRESS"
  status_repo "$STATUS_INDEX" "$src_slug" "$REPO_LOG" "$GIT_LFS_PROGRESS"
  printf '=== %s  %s/%s -> %s ===\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$SOURCE_PROJECT_KEY" "$src_slug" "$TARGET_PROJECT_KEY" >>"$REPO_LOG"

  _migrate_repo_steps "$src_slug" "$tgt_name"
  rc=$?
  R_DURATION=$((SECONDS - start))

  case "$rc" in
    0) R_STATUS=OK ;;
    2) R_STATUS=SKIPPED ;;
    *) R_STATUS=FAILED ;;
  esac
  if [ "$KEEP_WORKDIR" = false ] || { [ "$KEEP_WORKDIR" = on-failure ] && [ "$rc" != 1 ]; }; then
    rm -rf "$REPO_WORK"
  fi
  printf '=== result: %s %s (%ss)\n' "$R_STATUS" "$R_MESSAGE" "$R_DURATION" >>"$REPO_LOG"
  report_row
  case "$rc" in
    0) log_ok "[$src_slug] OK -> $TARGET_PROJECT_KEY/$R_TARGET_SLUG: $R_BRANCHES branches, $R_TAGS tags, $R_LFS_OBJECTS LFS objects ($(human_size "$R_LFS_BYTES")) in $(human_duration "$R_DURATION")${R_MESSAGE:+ - $R_MESSAGE}" ;;
    2) log_warn "[$src_slug] SKIPPED: $R_MESSAGE" ;;
    *) log_error "[$src_slug] FAILED: $R_MESSAGE (log: $REPO_LOG)" ;;
  esac
  return "$rc"
}

_migrate_repo_steps() {
  local src_slug="$1" tgt_name="$2"
  local sk="$SOURCE_PROJECT_KEY" tk="$TARGET_PROJECT_KEY" d="$REPO_WORK"
  local src_name forkable public src_lfs expected_slug tgt_slug body
  local src_url tgt_url default_ref lfs_file missing diff_file n
  local -a push_opts=()
  local prefix=""

  # ---- 1. source repository ---------------------------------------------------------
  status_step "reading the source repository"
  api_call SOURCE GET "/rest/api/1.0/projects/$sk/repos/$src_slug"
  if [ "$API_STATUS" != 200 ]; then
    R_MESSAGE="cannot read source repository: $(api_err_msg)"
    return 1
  fi
  src_name="$(jget .name)"
  forkable="$(jget .forkable true)"
  [ "$forkable" = false ] || forkable=true
  public="$(jget .public false)"
  if [ "$(jget .scmId)" != git ]; then
    R_MESSAGE="not a git repository"
    return 1
  fi

  api_call SOURCE GET "/rest/git-lfs/admin/projects/$sk/repos/$src_slug/enabled"
  case "$API_STATUS" in
    200 | 204) src_lfs=enabled ;;
    404) src_lfs=disabled ;;
    *) src_lfs=unknown ;;   # e.g. token without repository admin permission
  esac
  printf 'source: name=%s forkable=%s public=%s lfs=%s\n' "$src_name" "$forkable" "$public" "$src_lfs" >>"$REPO_LOG"

  # ---- 2. target repository ---------------------------------------------------------
  if [ -z "$tgt_name" ]; then
    tgt_name="$src_name"
    expected_slug="$(state_target_slug "$src_slug")"
    [ -n "$expected_slug" ] || expected_slug="$src_slug"
  else
    expected_slug="$(guess_slug "$tgt_name")"
  fi

  status_step "checking / creating the target repository"
  api_call TARGET GET "/rest/api/1.0/projects/$tk/repos/$expected_slug"
  case "$API_STATUS" in
    200)
      tgt_slug="$(jget .slug)"
      api_call TARGET GET "/rest/api/1.0/projects/$tk/repos/$tgt_slug/branches?limit=1"
      n="$(jget .size 0)"
      case "$EXISTING_REPO_POLICY" in
        fail) R_TARGET_SLUG="$tgt_slug"; R_MESSAGE="already exists on the target (EXISTING_REPO_POLICY=fail)"; return 1 ;;
        skip)
          if [ "$n" -gt 0 ]; then
            R_TARGET_SLUG="$tgt_slug"
            R_MESSAGE="already exists on the target and is not empty (EXISTING_REPO_POLICY=skip)"
            return 2
          fi
          log_info "[$src_slug] target repository exists but is empty: resuming"
          ;;
        sync)
          log_info "[$src_slug] target repository exists: synchronising (force-update of branches/tags)"
          prefix="+"
          [ "$SYNC_PRUNE" = true ] && push_opts+=(--prune)
          ;;
      esac
      ;;
    404)
      body="{\"name\":$(json_str "$tgt_name"),\"scmId\":\"git\""
      [ "$COPY_FORKABLE" = true ] && body="$body,\"forkable\":$forkable"
      body="$body}"
      api_call TARGET POST "/rest/api/1.0/projects/$tk/repos" "$body"
      if [ "$API_STATUS" != 201 ]; then
        R_MESSAGE="cannot create '$tgt_name' in $tk on the target: $(api_err_msg)"
        return 1
      fi
      tgt_slug="$(jget .slug)"
      log_info "[$src_slug] created $tk/$tgt_slug on the target"
      if [ "$COPY_PUBLIC" = true ] && [ "$public" = true ]; then
        api_call TARGET PUT "/rest/api/1.0/projects/$tk/repos/$tgt_slug" '{"public":true}'
        [ "$API_STATUS" = 200 ] || log_warn "[$src_slug] could not make the target repository public: $(api_err_msg)"
      fi
      ;;
    *)
      R_MESSAGE="cannot query the target repository: $(api_err_msg)"
      return 1
      ;;
  esac
  R_TARGET_SLUG="$tgt_slug"
  if [ "$tgt_slug" != "$expected_slug" ]; then
    log_warn "[$src_slug] the target slug is '$tgt_slug' (expected '$expected_slug'): clone URLs will differ"
  fi

  # ---- 3. fetch branches and tags ---------------------------------------------------
  src_url="$(git_url SOURCE "$sk" "$src_slug")"
  tgt_url="$(git_url TARGET "$tk" "$tgt_slug")"
  if [ "$KEEP_WORKDIR" = false ] || [ "$(git -C "$d" rev-parse --is-bare-repository 2>/dev/null)" != true ]; then
    rm -rf "$d"
    run_logged git init --bare --quiet "$d" || { R_MESSAGE="git init failed: $(log_tail 2)"; return 1; }
  else
    log_info "[$src_slug] reusing local copy $d (incremental fetch)"
  fi
  git -C "$d" config remote.origin.url "$src_url"
  git -C "$d" config --unset-all remote.origin.fetch 2>/dev/null
  git -C "$d" config --add remote.origin.fetch '+refs/heads/*:refs/heads/*'
  git -C "$d" config --add remote.origin.fetch '+refs/tags/*:refs/tags/*'
  git -C "$d" config remote.origin.tagOpt --no-tags
  git -C "$d" config remote.target.url "$tgt_url"

  # Safety lock: data is only ever pushed to the TARGET, never to the source repository
  case "$tgt_url" in "$TARGET_URL"/*) ;; *) R_MESSAGE="SAFETY: push URL $tgt_url is not on the target server"; return 1 ;; esac
  if [ "$tgt_url" = "$src_url" ]; then R_MESSAGE="SAFETY: source and target are the same repository"; return 1; fi

  log_info "[$src_slug] fetching branches and tags from the source"
  status_step "downloading branches and tags from the source (git)"
  if ! run_retry git -C "$d" fetch --progress --prune origin; then
    R_MESSAGE="git fetch from the source failed: $(log_tail 3)"
    return 1
  fi
  R_BRANCHES="$(git -C "$d" for-each-ref refs/heads | wc -l | tr -d ' ')"
  R_TAGS="$(git -C "$d" for-each-ref refs/tags | wc -l | tr -d ' ')"
  default_ref="$(git -C "$d" ls-remote --symref origin HEAD 2>>"$REPO_LOG" | awk '/^ref:/ { print $2; exit }')"
  if [ -n "$default_ref" ] && git -C "$d" show-ref --verify --quiet "$default_ref"; then
    git -C "$d" symbolic-ref HEAD "$default_ref"
    R_DEFAULT_BRANCH="${default_ref#refs/heads/}"
  fi

  if [ "$R_BRANCHES" -eq 0 ] && [ "$R_TAGS" -eq 0 ]; then
    if [ "$TARGET_ENABLE_LFS" = always ] || { [ "$TARGET_ENABLE_LFS" = auto ] && [ "$src_lfs" = enabled ]; }; then
      target_enable_lfs "$tgt_slug" || log_warn "[$src_slug] could not enable LFS on the target: $(api_err_msg)"
    fi
    R_MESSAGE="empty repository (created only)"
    return 0
  fi

  # ---- 4. Git LFS -------------------------------------------------------------------
  if [ "$MIGRATE_LFS" = true ] && [ "$src_lfs" != disabled ]; then
    log_info "[$src_slug] fetching LFS objects of all branches and tags"
    status_step "downloading the Git LFS objects of all branches/tags from the source"
    if ! run_retry git -C "$d" -c lfs.url="$src_url/info/lfs" lfs fetch --all origin; then
      if [ "$LFS_ALLOW_MISSING" = true ]; then
        log_warn "[$src_slug] some LFS objects could not be downloaded from the source (LFS_ALLOW_MISSING=true, continuing)"
        R_MESSAGE="incomplete LFS objects on the source"
      else
        R_MESSAGE="git lfs fetch from the source failed (set LFS_ALLOW_MISSING=true to ignore objects missing on the source): $(log_tail 3)"
        return 1
      fi
    fi
  elif [ "$MIGRATE_LFS" = true ]; then
    log_info "[$src_slug] Git LFS is disabled on the source repository: no LFS objects to migrate"
  fi
  lfs_file="$TMP_DIR/lfs_objects_$src_slug"
  list_local_lfs_objects "$d" >"$lfs_file"
  R_LFS_OBJECTS="$(wc -l <"$lfs_file" | tr -d ' ')"
  R_LFS_BYTES="$(awk '{ s += $2 } END { printf "%d", s }' "$lfs_file")"

  if [ "$TARGET_ENABLE_LFS" != never ] &&
    { [ "$R_LFS_OBJECTS" -gt 0 ] || [ "$TARGET_ENABLE_LFS" = always ] || [ "$src_lfs" = enabled ]; }; then
    status_step "enabling Git LFS on the target repository"
    if ! target_enable_lfs "$tgt_slug"; then
      if [ "$R_LFS_OBJECTS" -gt 0 ]; then
        R_MESSAGE="cannot enable Git LFS on the target repository ($(api_err_msg)) - is Git LFS enabled on the target server?"
        return 1
      fi
      log_warn "[$src_slug] could not enable Git LFS on the target: $(api_err_msg)"
    fi
  fi

  if [ "$R_LFS_OBJECTS" -gt 0 ]; then
    log_info "[$src_slug] uploading $R_LFS_OBJECTS LFS objects ($(human_size "$R_LFS_BYTES")) to the target"
    status_step "uploading $R_LFS_OBJECTS LFS objects ($(human_size "$R_LFS_BYTES")) to the target"
    if ! run_retry git -C "$d" -c lfs.url="$tgt_url/info/lfs" -c lfs.pushurl="$tgt_url/info/lfs" lfs push --all target; then
      R_MESSAGE="git lfs push to the target failed: $(log_tail 3)"
      return 1
    fi
  fi

  # ---- 5. push branches and tags ----------------------------------------------------
  log_info "[$src_slug] pushing $R_BRANCHES branches and $R_TAGS tags to the target"
  status_step "uploading $R_BRANCHES branches and $R_TAGS tags to the target (git)"
  if ! run_retry git -C "$d" push --progress --no-verify ${push_opts[@]+"${push_opts[@]}"} target \
    "${prefix}refs/heads/*:refs/heads/*" "${prefix}refs/tags/*:refs/tags/*"; then
    R_MESSAGE="git push to the target failed: $(log_tail 4)"
    return 1
  fi

  if [ "$COPY_DEFAULT_BRANCH" = true ] && [ -n "$R_DEFAULT_BRANCH" ]; then
    api_call TARGET PUT "/rest/api/1.0/projects/$tk/repos/$tgt_slug/branches/default" \
      "{\"id\":$(json_str "refs/heads/$R_DEFAULT_BRANCH")}"
    case "$API_STATUS" in
      200 | 204) ;;
      *) log_warn "[$src_slug] could not set the default branch '$R_DEFAULT_BRANCH' on the target: $(api_err_msg)" ;;
    esac
  fi

  # ---- 6. verification --------------------------------------------------------------
  status_step "verifying the copy on the target"
  diff_file="$TMP_DIR/refs_diff_$src_slug"
  local_refs "$d" >"$diff_file.local"
  remote_refs "$d" target >"$diff_file.target"
  comm -23 "$diff_file.local" "$diff_file.target" >"$diff_file"
  if [ -s "$diff_file" ]; then
    n="$(wc -l <"$diff_file" | tr -d ' ')"
    { echo "--- refs missing or different on the target:"; cat "$diff_file"; } >>"$REPO_LOG"
    R_MESSAGE="verification failed: $n branches/tags missing or different on the target"
    return 1
  fi
  n="$(comm -13 <(awk '{print $2}' "$diff_file.local" | sort) <(awk '{print $2}' "$diff_file.target" | sort) | wc -l | tr -d ' ')"
  if [ "$n" -gt 0 ]; then
    log_warn "[$src_slug] the target has $n branches/tags that do not exist on the source (use --sync --prune to delete them)"
  fi
  if ! diff <(local_refs "$d") <(remote_refs "$d" origin) >"$diff_file"; then
    { echo "--- refs changed on the source during the migration:"; cat "$diff_file"; } >>"$REPO_LOG"
    log_warn "[$src_slug] the source changed during the migration: re-run later with 03-migrate-project.sh --sync"
    R_MESSAGE="${R_MESSAGE:+$R_MESSAGE; }source changed during migration"
  fi

  if [ "$R_LFS_OBJECTS" -gt 0 ] && [ "$VERIFY_LFS" = true ]; then
    if ! missing="$(lfs_missing_on TARGET "$tk" "$tgt_slug" "$lfs_file")"; then
      R_MESSAGE="LFS verification on the target failed (batch API error)"
      return 1
    fi
    if [ "$missing" -gt 0 ]; then
      R_MESSAGE="LFS verification failed: $missing of $R_LFS_OBJECTS objects missing on the target"
      return 1
    fi
  fi
  rm -f "$lfs_file" "$diff_file" "$diff_file.local" "$diff_file.target"
  return 0
}
