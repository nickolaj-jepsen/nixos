set -euo pipefail

# Opens a path in the desktop's chosen editor, in the argv that editor wants:
# vscode's --reuse-window/--goto and ssh-remote+host, zed's path:line:col and
# ssh://host/path. Callers (Ghostty links, agent notes, the dynamic workspaces)
# stay editor-agnostic; fireproof.desktop.editor picks the binary at build time.
editor=@editor@
exe=@editorExe@

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
