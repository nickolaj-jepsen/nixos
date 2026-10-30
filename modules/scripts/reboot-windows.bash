#!/usr/bin/env bash
set -euo pipefail

# BootNext on the firmware's own Windows Boot Manager entry skips systemd-boot entirely,
# so this works even when Windows' ESP is on a disk systemd-boot can't chainload.
WINDOWS_NUM=$(efibootmgr | sed -n 's/^Boot\([0-9A-Fa-f]\{4\}\)\*\{0,1\} Windows Boot Manager.*/\1/p' | head -n 1)

if [ -z "$WINDOWS_NUM" ]; then
    echo "Error: No Windows Boot Manager entry in the firmware boot list (efibootmgr)."
    exit 1
fi

echo "Setting next boot to: Boot$WINDOWS_NUM (Windows Boot Manager)"

if [ "$EUID" -ne 0 ]; then
    sudo efibootmgr --quiet --bootnext "$WINDOWS_NUM"
    echo "Rebooting..."
    sudo systemctl reboot
else
    efibootmgr --quiet --bootnext "$WINDOWS_NUM"
    echo "Rebooting..."
    systemctl reboot
fi
