# Capturing screens

Capture local instances only, with dummy data. Save images to `onboard/assets/` and link them from Core features. Skip what you can't capture, and say so in the report. Features behind a real login stay **docs only**.

## Web

Use a throwaway profile, never the user's real browser or a browser tool that acts in it, since those carry their sign-ins.

```bash
chromium --headless --disable-gpu --no-first-run \
  --user-data-dir=/tmp/onboard/<project>-profile \
  --window-size=1280,800 --screenshot=<notes>/onboard/assets/<name>.png http://127.0.0.1:<port>/
```

DBus errors on stderr are harmless if the PNG is written. For a multi-step flow, use a browser MCP only if one is already available and runs headless and isolated. Don't add a new dependency for it.

## TUI and CLI

Save the text as a code block rather than an image, so it diffs. A private socket keeps this away from the user's tmux.

```bash
tmux -L onboard new-session -d -s cap -x 120 -y 40 '<command>'
tmux -L onboard send-keys -t cap '<keys>' Enter
tmux -L onboard capture-pane -p -t cap
tmux -L onboard kill-server
```

## Desktop

This is best effort: keyboard only, for apps that speak Wayland. A mouse-only app gets a first-screen screenshot at most, and an X11-only app is skipped. Electron apps may need `--ozone-platform=wayland`. The stack is `cage`, `grim` and `wtype`, from `nix shell` or local binaries.

The runtime dir must be private and the session variables unset, so nothing can reach the user's live compositor.

```bash
mkdir -p -m 700 /tmp/onboard/wl
XDG_RUNTIME_DIR=/tmp/onboard/wl WAYLAND_DISPLAY= DISPLAY= DBUS_SESSION_BUS_ADDRESS=disabled: \
  WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 cage -s -- <app> &
# once a wayland-* socket appears in that dir:
XDG_RUNTIME_DIR=/tmp/onboard/wl WAYLAND_DISPLAY=wayland-0 wtype '<keys>'
XDG_RUNTIME_DIR=/tmp/onboard/wl WAYLAND_DISPLAY=wayland-0 grim <notes>/onboard/assets/<name>.png
```

Stop `cage` when you're done.
