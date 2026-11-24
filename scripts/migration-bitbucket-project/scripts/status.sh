#!/usr/bin/env bash
# Shows where the migration is: repositories done, and for each repository being copied
# its current step, the data transferred and what is left. Reads output/ only.
# Usage: scripts/status.sh [-w]     -w = refresh every 5 seconds (Ctrl+C to quit)

OUT="$(cd "$(dirname "$0")/.." && pwd)/output"
P="$OUT/progress"

human() { awk -v b="${1:-0}" 'BEGIN { split("B KB MB GB TB", u, " "); i = 1
  while (b >= 1024 && i < 5) { b /= 1024; i++ }; printf (i == 1 ? "%d %s" : "%.1f %s"), b, u[i] }'; }
value() { sed -n "s/^$1=//p" "$2" 2>/dev/null | head -n 1; }

show() {
  local total done_n f repo step lfs_files lfs_bytes lfs git
  total=$(value total "$P/_run")
  done_n=$(sort -u "$OUT/done.txt" 2>/dev/null | grep -c .)
  echo "$(date '+%H:%M:%S')   repositories migrated: $done_n / ${total:-?}   (run started $(value started "$P/_run"))"
  [ -n "$(value finished "$P/_run")" ] && echo "run finished at $(value finished "$P/_run"): see the end of output/migration.log"
  for f in "$P"/*; do
    case "$f" in */_run | *.lfs) continue ;; esac
    [ -f "$f" ] || continue
    repo=${f##*/}
    step=$(value step "$f")
    echo
    echo "[$(value index "$f")] $repo: $step"
    # Git LFS: git-lfs writes "<direction> <file n>/<files> <bytes done>/<file size> <name>" per update
    read -r lfs_files lfs_bytes <<<"$(value lfs_total "$f")"
    if [ -s "$f.lfs" ] && [[ "$step" == *LFS* ]]; then
      lfs=$(awk '{ split($2, n, "/"); split($3, b, "/"); last = $1; files[$1] = n[2]
                   done[$1 " " n[1]] = b[1]; size[$1 " " n[1]] = b[2] }
                 END { for (k in done) { split(k, kk, " "); if (kk[1] != last) continue
                                         s += done[k]; if (done[k] == size[k]) c++ }
                       printf "%s %.0f %d %d", last, s, c, files[last] }' "$f.lfs")
      read -r dir bytes finished files <<<"$lfs"
      if [ -n "$lfs_bytes" ] && [ "$lfs_bytes" -gt 0 ] 2>/dev/null; then
        echo "    LFS ${dir}: $(human "$bytes") of $(human "$lfs_bytes")  ->  $(human $((lfs_bytes > bytes ? lfs_bytes - bytes : 0))) left   ($finished of $files files done)"
      else
        echo "    LFS ${dir}: $(human "$bytes")   ($finished of $files files done)"
      fi
    elif [ -n "$lfs_files" ] && [[ "$step" == *LFS* ]]; then
      echo "    LFS: $lfs_files files, $(human "$lfs_bytes") in total"
    fi
    # git: last progress line of the repository log ("Receiving objects:  45% (...), 1.20 GiB")
    if [[ "$step" == *"branches and tags"* && "$step" != *LFS* ]]; then
      git=$(tail -c 4000 "$OUT/logs/$repo.log" 2>/dev/null | tr '\r' '\n' | grep -E 'objects: ' | tail -n 1 | sed 's/^remote: //')
      [ -n "$git" ] && echo "    git: $git"
    fi
  done
}

if [ "${1:-}" = -w ]; then
  while :; do clear; show; sleep 5; done
else
  show
fi
