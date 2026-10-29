set -euo pipefail
# A glob stage below expands patterns directly; no match must mean no word, not the pattern.
shopt -s nullglob

# Shadows xdg-open on PATH. Ghostty hands clicked links to xdg-open with its own
# cwd ($HOME), so relative, `path:line` and ellipsis-trimmed paths (as printed by
# Claude Code etc.) never resolve. It also matches `api.slack.com/apps` as a path
# (the dot makes it look file-like), so a bare host needs a scheme. For Ghostty
# only: resolve paths against the cwds of the terminal's processes, send text
# files to VS Code, the rest on.
real=@xdgOpen@

[[ $# -eq 1 ]] || exec "$real" "$@"
parent_exe=$(readlink "/proc/$PPID/exe" 2>/dev/null || true)
[[ $parent_exe == *ghostty* ]] || exec "$real" "$@"

arg=$1
case $arg in
file://*)
  arg=${arg#file://}
  arg=/${arg#*/} # drop the host part
  arg=$(printf '%b' "${arg//%/\\x}")
  ;;
*://* | mailto:* | tel:* | magnet:* | news:* | ssh:*) exec "$real" "$arg" ;;
esac

# Strip `:line[:col]`, `:start-end` and `#Lline` suffixes.
line=""
col=""
if [[ $arg =~ ^(.+)#L([0-9]+)(-L?[0-9]+)?$ ]]; then
  arg=${BASH_REMATCH[1]}
  line=${BASH_REMATCH[2]}
elif [[ $arg =~ ^(.+[^0-9:]):([0-9]+)(:([0-9]+)|-[0-9]+)?$ ]]; then
  arg=${BASH_REMATCH[1]}
  line=${BASH_REMATCH[2]}
  col=${BASH_REMATCH[4]}
fi
[[ $arg == \~ || $arg == \~/* ]] && arg=$HOME${arg#\~}

# cwds of everything running under this Ghostty, newest process first.
mapfile -t cwds < <(
  ps -e -o pid=,ppid= --sort=-start_time |
    awk -v root="$PPID" '
      { pids[NR] = $1; parent[$1] = $2 }
      END {
        for (i = 1; i <= NR; i++) {
          p = pids[i]
          for (q = parent[p]; q > 1; q = parent[q]) if (q == root) { print p; break }
        }
      }' |
    while read -r pid; do readlink "/proc/$pid/cwd" 2>/dev/null || true; done |
    awk '!seen[$0]++'
)

# True for a link that is a host, not a path: `api.slack.com/apps`, `www.google.com`.
# A single dot is a filename (`foo.nix`), so a host needs a second dot or a path
# after it.
is_bare_url() {
  local host=${1%%/*}
  [[ $host =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}(:[0-9]+)?$ ]] || return 1
  [[ $1 == "$host"/* || $host == *.*.* ]]
}

# Prints the absolute path $1 resolves to, or nothing.
resolve() {
  local arg=$1
  local cwd files match suffix base
  if [[ $arg == /* ]]; then
    if [[ -e $arg ]]; then
      echo "$arg"
      return 0
    fi
  else
    for cwd in "${cwds[@]}"; do
      if [[ -e $cwd/$arg ]]; then
        echo "$cwd/$arg"
        return 0
      fi
    done
  fi

  # Shell globs (`views/*.sql`, `~/.pi/agent/*-api-key`): the first match, as sorted.
  if [[ $arg == *[*?[]* ]]; then
    local -a hits=()
    local hit
    local IFS= # no word splitting, so a pattern with spaces survives expansion
    # shellcheck disable=SC2206  # the unquoted pattern is the glob being expanded
    if [[ $arg == /* ]]; then
      hits=( $arg )
    else
      for cwd in "${cwds[@]}"; do
        hits=( $cwd/$arg )
        if ((${#hits[@]})); then break; fi
      done
    fi
    for hit in "${hits[@]}"; do
      if [[ -e $hit ]]; then
        echo "$hit"
        return 0
      fi
    done
  fi

  # A host is not a path: don't guess a tracked file named `apps` for `api.slack.com/apps`.
  if is_bare_url "$arg"; then return 0; fi

  # Trimmed (`…/foo/bar.nix`) or wrongly rooted path: match it as a suffix of a tracked file.
  suffix=${arg#…}
  suffix=${suffix#...}
  suffix=${suffix#./}
  suffix=${suffix#/}
  base=${suffix##*/}
  for cwd in "${cwds[@]}"; do
    files=$(git -C "$cwd" ls-files 2>/dev/null) || true
    match=$(awk -v s="/$suffix" '{ p = "/" $0; if (substr(p, length(p) - length(s) + 1) == s) { print; exit } }' <<<"$files")
    if [[ -n $match ]]; then
      echo "$cwd/$match"
      return 0
    fi
    # Claude gets the directory wrong more often than the file name: take a name
    # that only one tracked file has.
    match=$(awk -v b="$base" -F/ '$NF == b { n++; m = $0 } END { if (n == 1) print m }' <<<"$files")
    if [[ -n $match ]]; then
      echo "$cwd/$match"
      return 0
    fi
  done
  return 0
}

# Ghostty keeps prose punctuation inside the link too (`;`, `?`, `!`, `+`, `=`).
while [[ $arg == *';' || $arg == *'?' || $arg == *'!' || $arg == *'+' || $arg == *'=' ]]; do
  arg=${arg%?}
done
path=$(resolve "$arg")
# A sentence period stays in the link (`…/foo.nix.`); a `...` is prose ellipsis, not part of the path.
if [[ -z $path && $arg == *[!.]\. ]]; then
  arg=${arg%.}
  path=$(resolve "$arg")
fi

# Nothing on disk, but the link is a host: give it a scheme and let the browser have it.
if [[ -z $path ]] && is_bare_url "$arg"; then
  exec "$real" "https://$arg"
fi

if [[ -z $path ]]; then
  notify-send --app-name=Ghostty "Can't find path" "$1" || true
  exit 1
fi

if [[ -f $path && (! -s $path || $(file -b --mime-encoding "$path") != binary) ]]; then
  if [[ -n $line ]]; then
    exec code --reuse-window --goto "$path:$line${col:+:$col}"
  fi
  exec code --reuse-window "$path"
fi
exec "$real" "$path"
