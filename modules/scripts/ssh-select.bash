#!/usr/bin/env bash
set -euo pipefail

# Extract hosts from config and known_hosts
# shellcheck disable=SC2002
hosts=$(cat ~/.ssh/config ~/.ssh/config.d/* 2>/dev/null | grep -P "^Host ([^*]+)$" | awk '{print $2}' ; cat ~/.ssh/known_hosts 2>/dev/null | cut -f 1 -d ' ' | sed -e 's/,.*//g' | sort -u)

selected=$(echo "$hosts" | fzf --prompt="SSH > " --height=20% --layout=reverse)

if [ -n "$selected" ]; then
    echo "Connecting to $selected..."
    ssh "$selected"
fi
