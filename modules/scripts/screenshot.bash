#!/usr/bin/env bash
AREA=$(slurp -d)
grim -t ppm -g "$AREA" - | satty -f - --initial-tool=arrow --early-exit --copy-command="wl-copy" --action-on-enter="save-to-clipboard" --disable-notifications
