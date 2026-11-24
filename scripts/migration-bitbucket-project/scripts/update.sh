#!/usr/bin/env bash
# Downloads the latest version of these scripts from GitHub (eliorion/lab).
# Your .env and the output/ folder are never touched.
# The internet proxy is read from PROXY in .env, e.g. PROXY='http://10.240.157.9:8080'
# Usage: scripts/update.sh

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
URL="https://raw.githubusercontent.com/eliorion/lab/main/scripts/migration-bitbucket-project"
FILES="scripts/common.sh scripts/01-check-connections.sh scripts/02-test-single-repo.sh
       scripts/03-migrate-project.sh scripts/04-verify-project.sh README.md .env.example .gitignore .gitattributes"
TMP="$ROOT/scripts/.download.tmp"

# download FILE -> $TMP
download() {
  local opts=(-fsS --connect-timeout 20 -o "$TMP")
  [ -n "${PROXY:-}" ] && opts+=(--proxy "$PROXY")
  curl "${opts[@]}" "$URL/$1?nocache=$(date +%s)"
}

main() {
  # shellcheck source=/dev/null
  [ -f "$ROOT/.env" ] && source <(tr -d '\r' <"$ROOT/.env")
  echo "Downloading the latest version from $URL ${PROXY:+(proxy $PROXY)}"

  # 1. update this script first, then restart it (the new version may know new files)
  if [ "${1:-}" != --restarted ]; then
    download scripts/update.sh || { echo "FAILED: cannot reach GitHub (check PROXY in .env)"; rm -f "$TMP"; exit 1; }
    if ! cmp -s "$TMP" "$ROOT/scripts/update.sh" && bash -n "$TMP"; then
      mv -f "$TMP" "$ROOT/scripts/update.sh" 2>/dev/null || cp -f "$TMP" "$ROOT/scripts/update.sh"
      rm -f "$TMP"
      echo "  UPDATED  scripts/update.sh (restarting it)"
      exec bash "$ROOT/scripts/update.sh" --restarted
    fi
  fi

  # 2. every other file: replaced only if it changed and (for scripts) has no syntax error
  local file failed=0
  for file in $FILES; do
    if ! download "$file"; then
      echo "  FAILED   $file (download error)"
      failed=$((failed + 1))
    elif [[ "$file" == *.sh ]] && ! bash -n "$TMP"; then
      echo "  FAILED   $file (downloaded file is broken, kept the old one)"
      failed=$((failed + 1))
    elif cmp -s "$TMP" "$ROOT/$file"; then
      echo "  same     $file"
    else
      mv -f "$TMP" "$ROOT/$file"
      echo "  UPDATED  $file"
    fi
  done
  rm -f "$TMP"
  chmod +x "$ROOT"/scripts/*.sh
  [ "$failed" = 0 ] && echo "Up to date." || { echo "$failed file(s) could not be updated."; exit 1; }
}

# everything is inside main(): bash has read the whole file before it can be replaced
main "$@"; exit $?
