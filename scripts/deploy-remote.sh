#!/usr/bin/env -S bash -euo pipefail
# Installs hosts/<host> onto user@target with nixos-anywhere. FORMATS the target disks.
# Usage: scripts/deploy-remote.sh <host> <user@target>
# Optional LUKS TPM unlock after install:
#   sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 /dev/disk/by-partlabel/disk-main-luks
# Never add a TPM-only slot with desktop.autologin; boot would reach a signed-in desktop.

host=$1
target=$2

cd "$(dirname "$0")/.."

# Untracked files are invisible to the flake.
git add -- "hosts/$host" "secrets/hosts/$host"

temp=$(mktemp -d)
trap 'rm -rf "$temp"' EXIT

install -d -m755 "$temp/etc/ssh"

# The host SSH key, so agenix can decrypt secrets on the target during the install.
just age -d "./secrets/hosts/$host/id_ed25519.age" > "$temp/etc/ssh/ssh_host_ed25519_key"
chmod 600 "$temp/etc/ssh/ssh_host_ed25519_key"
cp "./secrets/hosts/$host/id_ed25519.pub" "$temp/etc/ssh/ssh_host_ed25519_key.pub"

nix --experimental-features 'nix-command flakes' run github:nix-community/nixos-anywhere -- \
    --flake ".#$host" \
    --disk-encryption-keys /luks-password <(just age -d ./secrets/luks-password.age) \
    --extra-files "$temp" \
    --target-host "$target"
