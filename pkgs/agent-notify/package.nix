# Desktop toast for coding-agent Notification hooks: `agent-notify <app name>`
# reads the hook JSON on stdin. Claude Code and Copilot CLI send the same fields
# (cwd, message), so one script serves both.
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
  # apart). Focused: no toast. Otherwise clicking the toast focuses it.
  # niri comes off PATH: its IPC has to match the running compositor.
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

    # --wait blocks until the toast closes, so detach it (fds included) or the
    # agent would wait on the hook.
    (
      action=$(notify-send --app-name="$app" --action=default=Focus --wait "$summary" "$message") || exit 0
      [ "$action" = default ] && niri msg action focus-window --id "''${window% *}"
    ) </dev/null >/dev/null 2>&1 &
    disown
  '';
  meta.platforms = lib.platforms.linux;
}
