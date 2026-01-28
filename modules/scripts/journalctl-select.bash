#!/usr/bin/env bash
set -euo pipefail

# Combine system and user units
units=$(
    {
        journalctl -F _SYSTEMD_UNIT 2>/dev/null | sed 's/^/system:/'
        journalctl --user -F _SYSTEMD_USER_UNIT 2>/dev/null | sed 's/^/user:/'
    } | sort -u
)

# Use fzf to select a unit and view its logs
# We set SHELL=bash to ensure the preview command works regardless of the user's default shell (e.g. fish)
# shellcheck disable=SC2016
selected=$(echo "$units" | SHELL=bash fzf \
    --prompt="Journal logs for unit > " \
    --height=40% \
    --layout=reverse \
    --preview '
        type=$(echo {} | cut -d: -f1)
        unit=$(echo {} | cut -d: -f2-)
        if [ "$type" = "user" ]; then
            SYSTEMD_COLORS=1 journalctl --user -u "$unit" -n 50 --no-pager --no-hostname 2>/dev/null | sed -E "s/^[[:space:]]+//"
        else
            SYSTEMD_COLORS=1 journalctl -u "$unit" -n 50 --no-pager --no-hostname 2>/dev/null | sed -E "s/^[[:space:]]+//"
        fi
    ' \
    --preview-window=right:70%,wrap)

if [ -n "$selected" ]; then
    type=$(echo "$selected" | cut -d: -f1)
    unit=$(echo "$selected" | cut -d: -f2-)

    if [ "$type" = "user" ]; then
        journalctl --user -u "$unit"
    else
        journalctl -u "$unit"
    fi
fi
