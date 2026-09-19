#!/usr/bin/env bash
set -euo pipefail

# SIGKILL the focused niri window's process, for apps that ignore close-window.

toast() {
  command -v dms >/dev/null 2>&1 && dms ipc toast "$1" "$2" >/dev/null 2>&1 || true
}

PID=$(niri msg --json focused-window | jq -r '.pid // empty')
if [ -z "$PID" ]; then
  toast error "No focused window with a known PID"
  exit 1
fi

COMM=$(ps -o comm= -p "$PID" || true)
# X11 windows report xwayland-satellite's PID; killing it takes down every X11 app.
if [ "$COMM" = "xwayland-satellite" ]; then
  toast error "Refusing to kill xwayland-satellite (X11 window)"
  exit 1
fi

if kill -9 "$PID"; then
  toast info "Killed $COMM ($PID)"
else
  toast error "Failed to kill $COMM ($PID)"
  exit 1
fi
