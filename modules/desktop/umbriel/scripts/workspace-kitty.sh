kitty_args=()
workspace=$(umbriel workspaces --json | jq -r '.[] | select(.focused) | .id') || workspace=""
if [[ -n "$workspace" ]]; then
  # NDW passes the project root to its initial Kitty. Read the launch
  # argument rather than the shell's cwd, which can change after cd.
  pids=$(umbriel windows --json | jq -r --arg ws "$workspace" '
    map(select(.workspace == $ws and .app_id == "kitty" and .pid > 0))
    | sort_by(.pid) | .[].pid
  ') || pids=""
  for pid in $pids; do
    argv=()
    mapfile -d "" -t argv 2>/dev/null < "/proc/$pid/cmdline" || continue
    dir=""
    for ((j = 1; j < ${#argv[@]}; j++)); do
      case "${argv[j]}" in
        --directory=*|--working-directory=*) dir="${argv[j]#*=}" ;;
        -d|--directory|--working-directory) j=$((j + 1)); dir="${argv[j]:-}" ;;
        --|[!-]*) break ;;
      esac
    done
    if [[ "$dir" == /* && -d "$dir" ]]; then
      kitty_args=(--directory "$dir")
      break
    fi
  done
fi
if [[ "${1:-}" != --in-column ]]; then
  exec kitty "${kitty_args[@]}"
fi

anchor=$(umbriel focused-window --json 2>/dev/null | jq -r '
  select(.active and .visible and (.floating or .fullscreen or .maximized_to_edges | not)
         and .scratchpad == "" and (.parent // "") == "") | .id
') || exec kitty "${kitty_args[@]}"
if [[ -z "$anchor" ]]; then
  exec kitty "${kitty_args[@]}"
fi
if ! umbriel workspaces --json | jq -e --arg id "$anchor" '
  any(.[]; .active and .layout == "scrolling" and .focused_window == $id)
' >/dev/null; then
  exec kitty "${kitty_args[@]}"
fi

read -r tag < /proc/sys/kernel/random/uuid
kitty "${kitty_args[@]}" --os-window-tag "$tag" &
# Pull from the right while the original row is focused: this joins its
# tab group or inserts directly below it, not at the end of the column.
for ((i = 0; i < 40; i++)); do
  windows=$(umbriel windows --json)
  if ! new=$(jq -er --arg tag "$tag" '.[] | select(.xdg_tag == $tag) | .id' <<< "$windows"); then
    sleep 0.05
    continue
  fi
  direction=$(jq -er --arg anchor "$anchor" --arg new "$new" '
    INDEX(.[]; .id) as $by_id | $by_id[$anchor] as $a | $by_id[$new] as $n
    | select($a != null and $n.active and $n.visible and ($n.floating | not)
             and ($a.floating | not) and $a.workspace == $n.workspace
             and $a.scratchpad == $n.scratchpad and $n.scratchpad == "")
    | ($n.column - $a.column) | if . == 1 then "right" elif . == -1 then "left" else empty end
  ' <<< "$windows") || exit 0
  umbriel msg window-focus "$anchor"
  [[ $(umbriel focused-window --json | jq -r 'select(.active) | .id') == "$anchor" ]] || exit 0
  umbriel msg "window-consume-from-$direction"
  umbriel msg window-focus "$new"
  exit 0
done
