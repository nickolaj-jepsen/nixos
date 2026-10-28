set -euo pipefail

# Shadows xdg-open on PATH. Ghostty hands clicked links to xdg-open with its own
# cwd ($HOME), so relative, `path:line` and ellipsis-trimmed paths (as printed by
# Claude Code etc.) never resolve. For Ghostty only: resolve them against the
# cwds of the terminal's processes, send text files to VS Code, the rest on.
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
    if [[ $arg == /* ]]; then
      mapfile -t hits < <(compgen -G "$arg")
    else
      for cwd in "${cwds[@]}"; do
        mapfile -t hits < <(compgen -G "$cwd/$arg")
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
  path=$(resolve "${arg%.}")
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
