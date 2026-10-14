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

path=""
if [[ $arg == /* && -e $arg ]]; then
  path=$arg
elif [[ $arg != /* ]]; then
  for cwd in "${cwds[@]}"; do
    if [[ -e $cwd/$arg ]]; then
      path=$cwd/$arg
      break
    fi
  done
fi

# Trimmed (`…/foo/bar.nix`) or wrongly rooted path: match it as a suffix of a tracked file.
if [[ -z $path ]]; then
  suffix=${arg#…}
  suffix=${suffix#...}
  suffix=${suffix#./}
  suffix=${suffix#/}
  for cwd in "${cwds[@]}"; do
    match=$(git -C "$cwd" ls-files 2>/dev/null |
      awk -v s="/$suffix" '{ p = "/" $0; if (substr(p, length(p) - length(s) + 1) == s) { print; exit } }') || true
    if [[ -n $match ]]; then
      path=$cwd/$match
      break
    fi
  done
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
