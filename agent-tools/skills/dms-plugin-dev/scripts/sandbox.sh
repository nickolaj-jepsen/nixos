#!/usr/bin/env bash
# Run real DMS with a plugin from the working tree in an isolated headless sway, and drive it.
#
# Its own HOME, runtime dir and no session bus, so nothing reaches the live desktop, and anything
# started with `run` or `bg` finds a daemon in here rather than the live one. One sandbox per
# working directory.
#
# Usage: sandbox.sh up|down|status|run|bg|key|move|click|wheel|shot|ipc|log [args]
# Output: shot prints the PNG path, log prints log lines, run prints what the command does.
# Everything else is silent on success. Errors go to stderr, exit 1.

set -euo pipefail

scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root=/tmp/dms-sandbox
base="$root/$(printf '%s' "$PWD" | sha1sum | cut -c1-8)"
run_dir="$base/run"
dms_log="$base/dms.log"

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

store_path() {
  mkdir -p "$root"
  nix build --no-link --print-out-paths "$@" 2>>"$root/nix.log" | head -1
}

# Each `export` here is what makes a process belong to the sandbox: `stop_all` finds them by it.
enter() {
  [ -f "$base/env" ] || die "no sandbox for $PWD, run: sandbox.sh up"
  # shellcheck disable=SC1091
  . "$base/env"
}

# By environment and never by name: the live shell runs the same store paths.
stop_all() {
  local proc pid
  for proc in /proc/[0-9]*; do
    if { tr '\0' '\n' <"$proc/environ"; } 2>/dev/null | grep -qx "XDG_RUNTIME_DIR=$run_dir"; then
      pid=${proc#/proc/}
      [ "$pid" = "$$" ] || kill "$pid" 2>/dev/null || true
    fi
  done
}

background() {
  local log=$1
  shift
  setsid "$@" >"$log" 2>&1 </dev/null &
}

bindings() {
  local python=$1 wlr wayland
  [ -e "$root/proto/protocols/wlr_virtual_pointer_unstable_v1" ] && return
  wlr="$(store_path nixpkgs#wlr-protocols)/share/wlr-protocols/unstable"
  # The default output is `bin`; the XML is in another.
  wayland="$(nix build --no-link --print-out-paths 'nixpkgs#wayland-scanner^*' 2>>"$root/nix.log" | while read -r out; do
    [ -e "$out/share/wayland/wayland.xml" ] && printf '%s/share/wayland/wayland.xml\n' "$out"
  done | head -1)"
  mkdir -p "$root/proto/protocols"
  "$python" -I "$scripts/wayland_bindings.py" "$root/proto/protocols" "$wayland" "$wlr/wlr-virtual-pointer-unstable-v1.xml"
}

up() {
  local plugins=() size=1600x1000 real_home=$HOME
  while [ $# -gt 0 ]; do
    case "$1" in
    --plugin)
      plugins+=("$2")
      shift 2
      ;;
    --size)
      size=$2
      shift 2
      ;;
    *) die "up takes --plugin <dir>=<id> and --size <w>x<h>" ;;
    esac
  done

  local dms dms_dir qs sway grim wtype python plugin enabled=""
  dms="$(readlink -f "$(command -v dms)")" || die "no dms on PATH"
  dms_dir="${DMS_SHELL_DIR:-$(dirname "$(dirname "$dms")")/share/quickshell/dms}"
  [ -d "$dms_dir" ] || die "no DMS at $dms_dir, set DMS_SHELL_DIR"
  # dms's embedded Qt runtime renders black without a GPU, so the UI runs on upstream quickshell.
  qs="$(store_path nixpkgs#quickshell)/bin"
  sway="$(store_path nixpkgs#sway)/bin/sway"
  grim="$(store_path nixpkgs#grim)/bin/grim"
  wtype="$(store_path nixpkgs#wtype)/bin/wtype"
  python="$(store_path --impure --expr '(builtins.getFlake "nixpkgs").legacyPackages.${builtins.currentSystem}.python3.withPackages (p: [p.pywayland])')/bin/python3"
  bindings "$python"

  stop_all
  # dms unpacks its embedded Qt runtime read-only under ~/.cache/dms/qtbase.
  chmod -R u+w "$base" 2>/dev/null || true
  rm -rf "$base"
  mkdir -p "$base/home/.config/dms/plugins" "$base/home/.cache/dms" "$base/home/.local/state/dms" "$run_dir"
  chmod 700 "$run_dir"

  # Your bar layout and colours, so the plugin sits where it does for you.
  cp -L "$real_home/.config/dms/settings.json" "$real_home/.config/dms/colors.json" "$base/home/.config/dms/" 2>/dev/null || true
  cp -L "$real_home/.cache/dms/dms-colors.json" "$base/home/.cache/dms/" 2>/dev/null || true
  cp -L "$real_home/.local/state/dms/session.json" "$base/home/.local/state/dms/" 2>/dev/null || true
  # The markers of what you've already dismissed, or a welcome window covers the screen.
  find -L "$real_home/.config/dms" -maxdepth 1 -type f -name '.*' -exec cp -L -t "$base/home/.config/dms/" {} +

  for plugin in "${plugins[@]}"; do
    cp -rL "${plugin%%=*}" "$base/home/.config/dms/plugins/${plugin##*=}"
    enabled+="${enabled:+,}\"${plugin##*=}\":{\"enabled\":true}"
  done
  printf '{%s}\n' "$enabled" >"$base/home/.config/dms/plugin_settings.json"
  chmod -R u+w "$base/home"

  printf 'output HEADLESS-1 resolution %s\nseat seat0 hide_cursor 0\ndefault_border none\n' "$size" >"$base/sway.conf"
  {
    printf 'export HOME=%q REAL_HOME=%q XDG_RUNTIME_DIR=%q\n' "$base/home" "$real_home" "$run_dir"
    printf 'export XDG_CONFIG_HOME=%q XDG_STATE_HOME=%q XDG_CACHE_HOME=%q XDG_DATA_HOME=%q\n' \
      "$base/home/.config" "$base/home/.local/state" "$base/home/.cache" "$base/home/.local/share"
    printf 'export DBUS_SESSION_BUS_ADDRESS=unix:path=%q\n' "$base/no-bus"
    printf 'unset LD_LIBRARY_PATH NIRI_SOCKET SWAYSOCK DISPLAY WAYLAND_DISPLAY CLAUDE_PID CLAUDE_CONFIG_DIR HYPRLAND_INSTANCE_SIGNATURE\n'
    printf 'export PATH=%q\n' "$qs:$PATH"
    printf 'DMS=%q DMS_DIR=%q GRIM=%q WTYPE=%q\n' "$dms" "$dms_dir" "$grim" "$wtype"
  } >"$base/env"
  enter

  WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 background "$base/sway.log" "$sway" -c "$base/sway.conf"
  local socket="" tries
  for tries in $(seq 1 100); do
    socket=$(find "$run_dir" -maxdepth 1 -name 'wayland-*' ! -name '*.lock' -printf '%f\n' | head -1)
    [ -n "$socket" ] && break
    sleep 0.1
  done
  [ -n "$socket" ] || die "sway did not start, see $base/sway.log"
  printf 'export WAYLAND_DISPLAY=%q XDG_SESSION_TYPE=wayland QT_QPA_PLATFORM=wayland\n' "$socket" >>"$base/env"
  printf 'export SWAYSOCK=%q\n' "$(find "$run_dir" -maxdepth 1 -name 'sway-ipc.*' | head -1)" >>"$base/env"
  enter

  mkfifo "$base/pointer.fifo"
  background "$base/pointer.log" "$python" -I "$scripts/pointer.py" "$root/proto" "$base/pointer.fifo" "${size%x*}" "${size#*x}"
  # Stays connected, so the seat keeps a keyboard between the short-lived `key` runs.
  background "$base/keyboard.log" "$wtype" -s 86400000

  background "$dms_log" "$DMS" run --qs-child -c "$DMS_DIR"
  for tries in $(seq 1 60); do
    grep -q 'Daemon plugin loaded\|DankBar: Plugin loaded' "$dms_log" 2>/dev/null && break
    sleep 0.5
  done
  sleep 2
}

verb="${1:-}"
shift || true

case "$verb" in
up) up "$@" ;;
down)
  stop_all
  ;;
status)
  enter
  pgrep -f "$base/sway.conf" >/dev/null && printf 'up %s\n' "$base" || die "sway is not running in $base"
  ;;
run)
  enter
  "$@"
  ;;
bg)
  enter
  name=$1
  shift
  background "$base/$name.log" "$@"
  ;;
key)
  enter
  "$WTYPE" "$@"
  ;;
move | click | wheel)
  enter
  printf '%s %s %s\n' "move" "$1" "$2" >"$base/pointer.fifo"
  sleep 0.25
  case "$verb" in
  click) printf 'click\n' >"$base/pointer.fifo" ;;
  wheel) printf 'wheel %s\n' "$3" >"$base/pointer.fifo" ;;
  esac
  sleep 0.25
  ;;
shot)
  enter
  file="$base/shot-${1:-$(date +%H%M%S)}.png"
  "$GRIM" "$file"
  printf '%s\n' "$file"
  ;;
ipc)
  enter
  "$DMS" ipc call "$@"
  ;;
log)
  [ -f "$dms_log" ] || die "no sandbox for $PWD, run: sandbox.sh up"
  grep -iE "${1:-.}" "$dms_log" | cut -c1-240 || true
  ;;
*) die "usage: sandbox.sh up|down|status|run|bg|key|move|click|wheel|shot|ipc|log [args]" ;;
esac
