#!/usr/bin/env bash
set -euo pipefail

# Native DMS toast feedback (no-op if dms isn't running / not on PATH).
toast() {
  command -v dms >/dev/null 2>&1 && dms ipc toast "$1" "$2" >/dev/null 2>&1 || true
}

AREA=$(slurp -d) || {
  toast error "Screenshot cancelled"
  exit 1
}

if grim -t ppm -g "$AREA" - | satty -f - --initial-tool=arrow --early-exit --copy-command="wl-copy" --action-on-enter="save-to-clipboard" --disable-notifications; then
  toast info "Screenshot copied to clipboard"
else
  toast error "Screenshot failed"
  exit 1
fi
