# Desktop toast for coding-agent hooks: `agent-notify <app name>` reads hook JSON
# on stdin and uses its `cwd` and `message` fields.
{
  lib,
  writeShellApplication,
  jq,
  libnotify,
}:
writeShellApplication {
  name = "agent-notify";
  runtimeInputs = [jq libnotify];
  # ghostty runs one process per window, so the niri window whose pid is an
  # ancestor of this hook hosts the session (the tab within it can't be told
  # apart). Focused: no toast. Otherwise clicking the toast focuses it, and
  # focusing or closing the window by any route closes the toast, so it
  # doesn't linger in the notification center.
  # niri and busctl come off PATH: their IPC has to match the running services.
  text = ''
    app=''${1:-Agent}
    input=$(cat)

    ancestors=()
    pid=$$
    while [ "$pid" -gt 1 ]; do
      ancestors+=("$pid")
      pid=$(sed -n 's/^PPid:[[:space:]]*//p' "/proc/$pid/status" 2>/dev/null) || break
    done

    window=""
    if windows=$(niri msg --json windows 2>/dev/null); then
      window=$(jq -r --args '
        first(.[] | select(.pid as $w | $ARGS.positional | any(. == ($w | tostring))))
        | "\(.id) \(.is_focused)"
      ' "''${ancestors[@]}" <<<"$windows")
    fi
    [ "''${window#* }" = true ] && exit 0

    project=$(jq -r --arg pwd "$PWD" '.cwd // $pwd | split("/") | last' <<<"$input")
    message=$(jq -r '.message // "Needs your attention"' <<<"$input")
    summary="$app · $project"

    if [ -z "$window" ]; then
      notify-send --app-name="$app" "$summary" "$message"
      exit 0
    fi

    id=''${window% *}
    # --wait blocks until the toast closes, so detach it (fds included) or the
    # agent would wait on the hook.
    (
      # Jobs get their own process group, so `kill %2` reaps the whole watcher pipeline.
      set -m
      fifo=$(mktemp -u)
      mkfifo "$fifo"
      notify-send --app-name="$app" --print-id --action=default=Focus --wait \
        "$summary" "$message" >"$fifo" &
      exec 3<"$fifo"
      rm -f "$fifo"
      read -r nid <&3 || exit 0

      close() {
        busctl --user call org.freedesktop.Notifications /org/freedesktop/Notifications \
          org.freedesktop.Notifications CloseNotification u "$nid" || true
      }

      niri msg --json event-stream \
        | jq --unbuffered -r --argjson w "$id" '
          select(.WindowFocusChanged.id == $w or .WindowClosed.id == $w
            or any(.WindowsChanged.windows[]?; .id == $w and .is_focused))
          | "hit"' \
        | { read -r _ && close; } &

      # EOF without an action: the toast closed (watcher, expiry or dismissal).
      read -r action <&3 && [ "$action" = default ] && niri msg action focus-window --id "$id" || true
      # DMS keeps clicked notifications in its center; close it there too.
      close
      kill %2 2>/dev/null || true
    ) </dev/null >/dev/null 2>&1 &
    disown
  '';
  meta.platforms = lib.platforms.linux;
}
