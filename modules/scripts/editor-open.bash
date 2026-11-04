set -euo pipefail

# Opens a path in the desktop's chosen editor, in the argv that editor wants:
# vscode's --reuse-window/--goto and ssh-remote+host, zed's path:line:col and
# ssh://host/path. Callers (Ghostty links, agent notes, the dynamic workspaces)
# stay editor-agnostic; fireproof.desktop.editor picks the name below. A machine
# with no GUI editor — a remote shell — asks the ssh connection's own reverse
# forward to open it on the other end, and opens nvim when there is no forward.
editor=@editor@

usage='usage: editor-open [--line N] [--col N] [--remote HOST] [PATH]'

line=""
col=""
remote=""
while (($# > 0)); do
  case $1 in
  --line)
    line=${2:?$usage}
    shift 2
    ;;
  --col)
    col=${2:?$usage}
    shift 2
    ;;
  --remote)
    remote=${2:?$usage}
    shift 2
    ;;
  --)
    shift
    break
    ;;
  -*)
    echo "editor-open: unknown option $1" >&2
    exit 2
    ;;
  *)
    break
    ;;
  esac
done

path=${1:-}
# A remote path is the other host's, so it cannot be resolved or defaulted here.
if [[ -z $path && -z $remote ]]; then
  echo "$usage" >&2
  exit 2
fi

# zed's CLI is `zeditor` from nixpkgs and `zed` from the cask or a distro package.
names=(code)
[[ $editor == zed ]] && names=(zed zeditor)
exe=""
for name in "${names[@]}"; do
  if command -v "$name" >/dev/null; then
    exe=$(command -v "$name")
    break
  fi
done

if [[ -z $exe ]]; then
  # A remote shell has the editor on this end of its ssh connection instead: ~/.ssh/config
  # forwards one request here to editor-open-bridge on the machine that runs the GUI, which
  # opens the path over the same ssh host and answers `ok`. Anything else — no forward, a
  # host the bridge does not know, an editor that would not start — falls through to nvim.
  if [[ -z $remote && -n ${EDITOR_OPEN_HOST:-} ]]; then
    # The group keeps bash's own "connection refused" off the terminal while the fd stays.
    if { exec 3<>/dev/tcp/127.0.0.1/@bridgePort@; } 2>/dev/null; then
      reply=""
      if printf '%s\t%s\t%s\t%s\n' "$EDITOR_OPEN_HOST" "$path" "$line" "$col" >&3 &&
        IFS= read -r -t 5 reply <&3 && [[ $reply == ok ]]; then
        exit 0
      fi
    fi
  fi
  if [[ -n $remote ]]; then
    echo "editor-open: no $editor on PATH here, so $remote:$path cannot be opened" >&2
    exit 1
  fi
  # No GUI editor to hand it to: the terminal's own editor is what is left.
  if ! command -v nvim >/dev/null; then
    echo "editor-open: no $editor or nvim on PATH" >&2
    exit 1
  fi
  position=()
  [[ -n $line ]] && position+=("+$line")
  exec nvim "${position[@]}" "$path"
fi

case $editor in
zed)
  if [[ -n $remote ]]; then
    target=${path#/}
    exec "$exe" "ssh://$remote/${target:-~}"
  fi
  # zed takes the position inside the path argument, and reuses a window by default.
  exec "$exe" "$path${line:+:$line}${col:+:$col}"
  ;;
vscode)
  if [[ -n $remote ]]; then
    args=(--remote "ssh-remote+$remote")
    [[ -n $path ]] && args+=("$path")
    exec "$exe" "${args[@]}"
  fi
  if [[ -n $line ]]; then
    exec "$exe" --reuse-window --goto "$path:$line${col:+:$col}"
  fi
  exec "$exe" --reuse-window "$path"
  ;;
*)
  echo "editor-open: unknown editor '$editor'" >&2
  exit 1
  ;;
esac
