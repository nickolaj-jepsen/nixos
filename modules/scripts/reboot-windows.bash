#!/usr/bin/env bash
set -euo pipefail

# Find windows entry id using bootctl
WINDOWS_ID=$(bootctl list --json=short | jq -r '.[] | select(.title != null) | select(.title | ascii_downcase | contains("windows")) | .id' | head -n 1)

if [ -z "$WINDOWS_ID" ]; then
    # Fallback to checking the ID itself
    WINDOWS_ID=$(bootctl list --json=short | jq -r '.[] | select(.id | ascii_downcase | contains("windows")) | .id' | head -n 1)
fi

if [ -z "$WINDOWS_ID" ]; then
    echo "Error: No Windows boot entry found in systemd-boot."
    exit 1
fi

echo "Setting next boot to: $WINDOWS_ID"

# Check if we have root, if not, try to use sudo
if [ "$EUID" -ne 0 ]; then
    sudo bootctl set-oneshot "$WINDOWS_ID"
    echo "Rebooting..."
    sudo systemctl reboot
else
    bootctl set-oneshot "$WINDOWS_ID"
    echo "Rebooting..."
    systemctl reboot
fi
