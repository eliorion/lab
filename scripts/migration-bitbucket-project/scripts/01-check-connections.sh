#!/usr/bin/env bash
# Checks everything before a migration. Changes nothing on either server.
# Usage: scripts/01-check-connections.sh

source "$(dirname "$0")/common.sh"
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

echo
if [ "$FAILS" -gt 0 ]; then echo "$FAILS check(s) FAILED"; exit 1; fi
echo "All checks passed. Next: scripts/02-test-single-repo.sh <repo-slug>"
