#!/usr/bin/env -S bash -euo pipefail
# Writes hosts/<host>/facter.json from nixos-facter, locally or over ssh on a running
# target. Reads hardware only; never reinstalls.
# Usage: scripts/factor.sh <host> [user@target]

host=$1
target=${2:-}
facter="nix --experimental-features 'nix-command flakes' run nixpkgs#nixos-facter"

cd "$(dirname "$0")/.."

if [ ! -d "hosts/$host" ]; then
    echo "Error: Host '$host' does not exist in ./hosts/" >&2
    exit 1
fi

report=$(mktemp)
trap 'rm -f "$report"' EXIT

if [ -z "$target" ]; then
    sudo sh -c "$facter" > "$report"
else
    ssh "$target" "sudo sh -c \"$facter\"" > "$report"
fi

install -m644 "$report" "hosts/$host/facter.json"
