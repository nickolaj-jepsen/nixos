#!/usr/bin/env bash
# Usage: noise.sh <base> <head>
# Classifies each file changed between merge-base(base, head) and head, one
# tab-separated line per file: class, status, +added, -deleted, path.
# Classes, most mechanical first:
#   lock       lockfile
#   generated  linguist-generated, a generated-code marker, snapshots, minified
#   binary     no text diff
#   renamed    pure rename (R100)
#   format     whitespace only, or no syntactic change per difft (when on PATH)
#   moved      every changed line is a block moved within the diff
#   edit       anything else: the part worth reading
# Needs both commits locally (fetch the PR head first).
set -euo pipefail
[ $# -eq 2 ] || {
  echo "usage: noise.sh <base> <head>" >&2
  exit 2
}
head=$(git rev-parse --verify "$2^{commit}")
base=$(git merge-base "$1" "$head")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
git() { command git --no-pager "$@"; }

# Per-file moved/changed line counts, from one whole-diff pass so moves across
# files count. Moved lines get fixed colours; everything else is plain.
git -c color.diff.oldMoved=magenta -c color.diff.newMoved=cyan \
  -c color.diff.oldMovedAlternative=magenta -c color.diff.newMovedAlternative=cyan \
  -c color.diff.old=red -c color.diff.new=green -c color.diff.meta=normal -c color.diff.frag=normal \
  diff --color=always --color-moved=zebra --color-moved-ws=allow-indentation-change \
  -M "$base" "$head" |
  awk -v ESC=$'\033' '
    { raw = $0; text = $0; gsub(ESC "\\[[0-9;]*m", "", text) }
    text ~ /^diff --git / { sub(/^diff --git a\/.* b\//, "", text); file = text; next }
    text ~ /^(\+\+\+|---) / { next }
    text ~ /^[+-][ \t]*$/ { next }
    text ~ /^[+-]/ {
      changed[file]++
      if (index(raw, ESC "[35m") == 1 || index(raw, ESC "[36m") == 1) moved[file]++
    }
    END { for (f in changed) printf "%s\t%d\t%d\n", f, changed[f], moved[f] + 0 }
  ' >"$tmp/moved"

git diff -M --name-status "$base" "$head" | while IFS=$'\t' read -r status a b; do
  path=${b:-$a}
  old=$a
  read -r add del _ < <(git diff -M --numstat "$base" "$head" -- "$old" "$path" | awk '{a+=$1; d+=$2} END {print a+0, d+0, ""}' 2>/dev/null || echo "0 0")
  class=edit
  name=${path##*/}
  case "$name" in
  *.lock | package-lock.json | pnpm-lock.yaml | npm-shrinkwrap.json | go.sum | *.lock.json) class=lock ;;
  esac
  if [ "$class" = edit ]; then
    case "$path" in
    *__snapshots__/* | *.snap | *.min.js | *.min.css | *.map) class=generated ;;
    esac
  fi
  if [ "$class" = edit ] && [ "$(git check-attr linguist-generated -- "$path" | awk '{print $NF}')" = true ]; then
    class=generated
  fi
  if [ "$class" = edit ] && [ "${status:0:1}" != D ] &&
    git show "$head:$path" 2>/dev/null | head -n 5 | grep -qiE '@generated|do not edit|code generated'; then
    class=generated
  fi
  if [ "$class" = edit ] && [ "$(git diff -M --numstat "$base" "$head" -- "$old" "$path" | cut -f1 | head -n1)" = - ]; then
    class=binary
  fi
  if [ "$class" = edit ] && [ "$status" = R100 ]; then
    class=renamed
  fi
  if [ "$class" = edit ] && [ "${status:0:1}" != A ] && [ "${status:0:1}" != D ]; then
    if git diff -w --ignore-blank-lines --quiet "$base" "$head" -- "$old" "$path"; then
      class=format
    elif command -v difft >/dev/null; then
      ext=${name##*.}
      [ "$ext" = "$name" ] && ext=txt
      git show "$base:$old" >"$tmp/a.$ext" 2>/dev/null &&
        git show "$head:$path" >"$tmp/b.$ext" 2>/dev/null &&
        difft --check-only --exit-code "$tmp/a.$ext" "$tmp/b.$ext" >/dev/null 2>&1 &&
        class=format
    fi
  fi
  if [ "$class" = edit ]; then
    read -r changed movedn < <(awk -F'\t' -v p="$path" '$1 == p {print $2, $3}' "$tmp/moved")
    [ "${changed:-0}" -gt 0 ] && [ "${movedn:-0}" -eq "${changed:-0}" ] && class=moved
  fi
  printf '%s\t%s\t+%s\t-%s\t%s\n' "$class" "$status" "$add" "$del" "$path"
done | awk -F'\t' 'BEGIN { split("lock generated binary renamed format moved edit", o, " "); for (i in o) r[o[i]] = i } { print r[$1] "\t" $0 }' | sort -t$'\t' -k1,1n -s | cut -f2-
