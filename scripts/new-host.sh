#!/usr/bin/env -S bash -euo pipefail
# Creates hosts/<host>/ (a card, not an install) plus the host SSH key, then rekeys.
# Usage: scripts/new-host.sh <host> <username>

host=$1
user=$2

cd "$(dirname "$0")/.."

if [ -d "hosts/$host" ]; then
    echo "Error: Host '$host' already exists."
    exit 1
fi

temp=$(mktemp -d)
trap 'rm -rf "$temp"' EXIT

echo "Setting up folders"
mkdir -p "secrets/hosts/$host" "hosts/$host"

# Discovery is the presence of host.nix; the card shape is documented in docs/hosts.md.
cat > "$temp/host.nix" <<'EOF'
# @HOST@'s host card: the feature toggles it enables + its facts. The
# presence of this file is what makes hosts/@HOST@/ a discovered host.
# Every host file is a card (shape: docs/hosts.md): enable features via
# `shared.fireproof.<feature>.enable = true`, add settings for the host's
# class under its bucket, and host-specific home-manager tweaks under
# `homeManager`.
{
  shared = {
    fireproof.hostname = "@HOST@";
    fireproof.username = "@USER@";
    # Enable features, e.g.:
    # fireproof.desktop.enable = true;
    # fireproof.dev.enable = true;
  };
}
EOF
sed -e "s/@HOST@/$host/g" -e "s/@USER@/$user/g" "$temp/host.nix" > "hosts/$host/host.nix"

release=$(nix --experimental-features 'nix-command flakes' eval --inputs-from . --raw nixpkgs#lib.trivial.release)
cat > "hosts/$host/state-version.nix" <<EOF
# Install-time release; never bump.
{
  nixos.system.stateVersion = "$release";
  homeManager.home.stateVersion = "$release";
}
EOF

echo "Generating SSH key for $user@$host"
ssh-keygen -q -t ed25519 -f "$temp/id_ed25519" -C "$user@$host" -N ""
cp "$temp/id_ed25519.pub" "secrets/hosts/$host/id_ed25519.pub"

echo "Encrypting SSH key"
just age -e "$temp/id_ed25519" -o "secrets/hosts/$host/id_ed25519.age"

# Untracked files are invisible to the flake, so agenix-rekey would skip the new host.
git add -- "hosts/$host" "secrets/hosts/$host"
echo "Secret rekeying..."
just secret-rekey

echo "Host '$host' created and staged; it is discovered automatically."
echo "Edit hosts/$host/host.nix to enable features via fireproof.*.enable — see modules/base/fireproof.nix."
echo "Add \"$host\" to trustedHosts in modules/system/ssh.nix so the other hosts accept its SSH key."
