nixcmd := "nix --experimental-features 'nix-command flakes'"

# Built bootstrap ISOs carry a private host key, so they live outside the repo and the world-readable store.
bootstrap_iso_dir := cache_directory() / "bootstrap-iso"

# Current Nix system double (e.g. x86_64-linux, aarch64-darwin); agenix-rekey is per-system.
system := `nix --experimental-features 'nix-command flakes' eval --impure --raw --expr 'builtins.currentSystem'`

@_default:
    just --list

[private]
_confirm message:
    #!/usr/bin/env -S bash -e
    read -p "{{ message }} (y/N) " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]] || { echo "Aborted"; exit 1; }

[doc("Build a flake output")]
[group('tools')]
build target *ARGS="":
    @if command -v nom >/dev/null 2>&1; then \
        nom build {{ justfile_directory() }}#{{ target }} {{ ARGS }}; \
    else \
        nix build {{ justfile_directory() }}#{{ target }} {{ ARGS }}; \
    fi

[doc('Build a nixos configuration')]
[group('deploy')]
build-system hostname=`hostname -s` *ARGS="":
    @just build nixosConfigurations."{{ hostname }}".config.system.build.toplevel {{ ARGS }}

[doc('Write hosts/<host>/facter.json from nixos-facter, run here or over ssh on a running target (never reinstalls)')]
[group('deploy')]
factor hostname=`hostname -s` target='':
    #!/usr/bin/env -S bash -e
    target="{{ target }}"
    if [ ! -d "hosts/{{ hostname }}" ]; then
        echo "Error: Host '{{ hostname }}' does not exist in ./hosts/"
        exit 1
    fi
    report=$(mktemp)
    trap 'rm -f "$report"' EXIT
    if [ -z "$target" ]; then
        sudo {{ nixcmd }} run nixpkgs#nixos-facter > "$report"
    else
        ssh "$target" "sudo {{ nixcmd }} run nixpkgs#nixos-facter" > "$report"
    fi
    install -m644 "$report" "hosts/{{ hostname }}/facter.json"

[doc('Wrapper for nixos-rebuild switch')]
[group("deploy")]
switch hostname=`hostname -s` target='' *ARGS="":
    #!/usr/bin/env -S bash -e
    target="{{ target }}"
    if [ -z "$target" ]; then
        sudo nixos-rebuild switch --flake .#{{ hostname }} {{ ARGS }}
        just _failed-units
    else
        nixos-rebuild switch \
            --flake .#{{ hostname }} \
            --use-substitutes \
            --target-host {{ target }} \
            --sudo {{ ARGS }}
    fi

[doc('Wrapper for nixos-rebuild boot')]
[group("deploy")]
boot hostname=`hostname -s` *ARGS="":
    sudo nixos-rebuild boot --flake .#{{ hostname }} {{ ARGS }}

[doc('Wrapper for nixos-rebuild test')]
[group("deploy")]
test hostname=`hostname -s` *ARGS="":
    sudo nixos-rebuild test --flake .#{{ hostname }} {{ ARGS }}
    @just _failed-units

# Activation can succeed while units fail; surface them instead of leaving them to be found later.
[private]
_failed-units:
    #!/usr/bin/env -S bash -e
    for scope in --system --user; do
        failed=$(systemctl "$scope" --failed --no-legend --plain | awk '{print $1}')
        if [ -n "$failed" ]; then
            echo "⚠ failed units ($scope):"
            echo "$failed" | sed 's/^/  /'
            echo "  inspect: journalctl ${scope/--system/} -b -u <unit>"
        fi
    done

[doc('Build a home-manager host (class = "home") activation package')]
[group("deploy")]
home-build hostname *ARGS="":
    @just build homeConfigurations."{{ hostname }}".activationPackage {{ ARGS }}

[doc('Activate a home-manager host: locally (run ON the host as its user), or push to a remote target over ssh')]
[group("deploy")]
home-switch hostname target='':
    #!/usr/bin/env -S bash -e
    target="{{ target }}"
    out=$({{ nixcmd }} build --no-link --print-out-paths \
        "{{ justfile_directory() }}#homeConfigurations.{{ hostname }}.activationPackage")
    if [ -z "$target" ]; then
        "$out/activate"
    else
        {{ nixcmd }} copy --to "ssh://$target" "$out"
        ssh "$target" "$out/activate"
    fi

[doc('Build a nix-darwin host (class = "darwin") — aarch64-darwin, so run ON the Mac')]
[group("deploy")]
darwin-build hostname=`hostname -s` *ARGS="":
    @just build darwinConfigurations."{{ hostname }}".system {{ ARGS }}

[doc('Preview changes vs the current Mac system (nvd diff; run ON the Mac)')]
[group("deploy")]
darwin-diff hostname=`hostname -s`: (darwin-build hostname)
    nvd diff /run/current-system {{ justfile_directory() }}/result

# First-time bootstrap on a fresh Mac (run ON the Mac):
#   1. Install Nix (Determinate or upstream) with flakes enabled.
#   2. sudo ssh-keygen -A                      # create /etc/ssh/ssh_host_ed25519_key
#   3. Replace secrets/hosts/<h>/id_ed25519.{pub,age} with this Mac's real host key
#      (the committed pub is a placeholder), then `just secret-rekey` (YubiKey).
#      If <h> isn't in trustedHosts (modules/system/ssh.nix) yet, add it now that the
#      real key is committed, and switch the other hosts so they accept it.
#   4. nix run nix-darwin/nix-darwin-26.05#darwin-rebuild -- switch --flake .#<h>
#   nix-homebrew installs Homebrew itself on the first switch (slow); review
#   homebrew.onActivation.cleanup first.
#   5. sudo systemsetup -setremotelogin on     # enable sshd (Remote Login); nix
#      manages the hardening drop-in + authorized_keys, but not the on/off bit.
#      Confirm Settings > General > Sharing > Remote Login access is "All users"
#      (or includes the user). Key-only auth; reach it over Tailscale/LAN.
[doc('Build + activate a nix-darwin host (run ON the Mac; see bootstrap notes in the justfile for the first run)')]
[group("deploy")]
darwin-switch hostname=`hostname -s` *ARGS="":
    sudo darwin-rebuild switch --flake .#{{ hostname }} {{ ARGS }}

[doc('Use nixos-anywhere to deploy to a remote host')]
[group('deploy')]
deploy-remote hostname target: (_confirm "Deploy " + hostname + " to " + target + "? This will FORMAT disks on the target.")
    #!/usr/bin/env -S bash -e
    # Untracked files are invisible to the flake.
    git add -- "hosts/{{ hostname }}" "secrets/hosts/{{ hostname }}"

    temp=$(mktemp -d)
    trap "rm -rf $temp" EXIT


    install -d -m755 "$temp/etc/ssh"

    # Copy ssh key to decrypt agenix secrets
    just age -d "./secrets/hosts/{{ hostname }}/id_ed25519.age" > "$temp/etc/ssh/ssh_host_ed25519_key"
    chmod 600 "$temp/etc/ssh/ssh_host_ed25519_key"

    cp "./secrets/hosts/{{ hostname }}/id_ed25519.pub" "$temp/etc/ssh/ssh_host_ed25519_key.pub"

    # Deploy
    {{ nixcmd }} run github:nix-community/nixos-anywhere -- \
        --flake .#{{ hostname }} \
        --disk-encryption-keys /luks-password <(just age -d ./secrets/luks-password.age) \
        --extra-files "$temp" \
        --target-host "{{ target }}"

[doc("Build a live image of a host's own config (no host key baked in; to install a host, use bootstrap-iso)")]
[group('tools')]
iso hostname:
    {{ nixcmd }} build .#nixosConfigurations.{{ hostname }}.config.system.build.images.iso-installer

[doc('Generate Markdown reference for the fireproof.* options into docs/')]
[group('tools')]
docs:
    #!/usr/bin/env -S bash -e
    mkdir -p docs
    out=$({{ nixcmd }} build --no-link --print-out-paths .#fireproof-docs)
    install -m 644 "$out" docs/fireproof-options.md
    echo "Wrote docs/fireproof-options.md"

[doc('Build a host-specific bootstrap ISO (host SSH key + repo baked in) into ~/.cache/bootstrap-iso/')]
[group('deploy')]
bootstrap-iso hostname:
    #!/usr/bin/env -S bash -e
    if [ ! -f "secrets/hosts/{{ hostname }}/id_ed25519.age" ]; then
        echo "No host key for '{{ hostname }}'. Run: just new-host {{ hostname }} <username>"
        exit 1
    fi
    if [ ! -d "hosts/{{ hostname }}" ]; then
        echo "Host '{{ hostname }}' not in ./hosts/. Run: just new-host {{ hostname }} <username>"
        exit 1
    fi

    # nixos-install is the first thing to force the rekeyed files, and on the target that is after disko has wiped the disk.
    {{ nixcmd }} eval --raw ".#nixosConfigurations.{{ hostname }}.config" --apply 'c: builtins.deepSeq (map (s: toString s.file) (builtins.attrValues c.age.secrets ++ builtins.concatMap (u: builtins.attrValues (u.age.secrets or {})) (builtins.attrValues c.home-manager.users))) "ok"' >/dev/null ||
        { echo "Secrets for {{ hostname }} aren't all rekeyed. Run: just secret-rekey"; exit 1; }

    temp=$(mktemp -d)
    # Everything built on the payload is a world-readable copy of the key, so purge on every exit, not only success.
    # Images drop their references: take outputs from the dependent .drvs, since `store delete` refuses a partial set.
    purge() {
        [ -f "$temp/payload/id_ed25519" ] || return 0
        rm -f "$temp/result"
        local payload closure built
        if payload=$({{ nixcmd }} store add --dry-run --name source "$temp/payload") &&
            closure=$(nix-store --query --referrers-closure "$payload" 2>/dev/null) &&
            built=$(nix-store --query --outputs $(grep '\.drv$' <<<"$closure") </dev/null) &&
            {{ nixcmd }} store delete $closure $built; then
            echo "Purged the plaintext host key from the Nix store."
        elif [ -e "$payload" ]; then
            echo "Warning: couldn't purge the plaintext host key from the Nix store (see above)." >&2
        fi
    }
    trap 'purge; rm -rf "$temp"' EXIT

    echo "Decrypting host SSH key (touch YubiKey if prompted)..."
    install -d -m700 "$temp/payload"
    just age -d "secrets/hosts/{{ hostname }}/id_ed25519.age" > "$temp/payload/id_ed25519"
    chmod 600 "$temp/payload/id_ed25519"
    cp "secrets/hosts/{{ hostname }}/id_ed25519.pub" "$temp/payload/id_ed25519.pub"
    override="--override-input bootstrap-payload path:$temp/payload"

    echo "Building bootstrap ISO for {{ hostname }}..."
    just build "nixosConfigurations.bootstrap-{{ hostname }}.config.system.build.isoImage" \
        $override --out-link "$temp/result"
    iso="{{ bootstrap_iso_dir }}/{{ hostname }}.iso"
    install -d -m700 "{{ bootstrap_iso_dir }}"
    install -m600 "$temp"/result/iso/*.iso "$iso"
    echo "ISO built: $iso"
    echo "It holds the private host key: delete it once flashed (bootstrap-flash does)."

[doc('Flash a host-specific bootstrap ISO to a USB drive')]
[group('deploy')]
bootstrap-flash hostname device: (_confirm "Flash bootstrap ISO for " + hostname + " to " + device + "? This will ERASE ALL DATA on " + device + ".")
    #!/usr/bin/env -S bash -e
    if [ ! -b "{{ device }}" ]; then
        echo "Error: {{ device }} is not a block device"
        exit 1
    fi

    just bootstrap-iso {{ hostname }}

    iso_file="{{ bootstrap_iso_dir }}/{{ hostname }}.iso"
    echo "Flashing $iso_file to {{ device }}..."
    sudo dd if="$iso_file" of="{{ device }}" bs=4M status=progress oflag=sync
    rm -f "$iso_file"
    echo "Done! You can now boot from {{ device }}"
    echo "Wipe or reflash it after the install: it holds the host's private key."

[doc('Runs (r)age with yubikey identity')]
[group('secret')]
age *ARGS="--help":
    @rage {{ ARGS }} -i ./secrets/yubikey-identity.pub

[doc('Decrypt a file to stdout')]
[group('secret')]
decrypt file:
    just age -d {{ file }}

[doc('Edit an encrypted secret in $EDITOR (PATH to the .age file) and stage it')]
[group('secret')]
secret-edit file:
    #!/usr/bin/env -S bash -e
    {{ nixcmd }} run .#agenix-rekey.{{ system }}.edit-view edit "{{ file }}"
    # Stage it: `nix` flake eval ignores git-untracked files, so a new secret is invisible until added.
    if [ -f "{{ file }}" ]; then git add -- "{{ file }}"; fi

# rm first: secret-edit would decrypt the old file to prefill, needing a touch.
[doc('Write a secret from stdin, no $EDITOR (PATH to the .age file) - for agents/scripts. Needs no YubiKey; refuses to overwrite unless force=1')]
[group('secret')]
secret-write file force="":
    #!/usr/bin/env -S bash -e
    if [ -t 0 ]; then
        echo "Error: expects the plaintext secret on stdin, e.g. printf 'KEY=value\n' | just secret-write {{ file }}" >&2
        exit 1
    fi
    if [ -e "{{ file }}" ] && [ -z "{{ force }}" ]; then
        echo "Error: {{ file }} already exists, and stdin would replace it wholesale." >&2
        echo "Use 'just secret-edit {{ file }}' to edit in place (YubiKey), or pass force=1 to discard the current value." >&2
        exit 1
    fi
    umask 077
    temp=$(mktemp -d)
    trap "rm -rf $temp" EXIT
    cat > "$temp/plaintext"
    if [ ! -s "$temp/plaintext" ]; then
        echo "Error: stdin was empty; refusing to write an empty secret." >&2
        exit 1
    fi
    printf '#!/usr/bin/env bash\ncat %q > "$1"\n' "$temp/plaintext" > "$temp/editor"
    chmod +x "$temp/editor"
    rm -f "{{ file }}"
    EDITOR="$temp/editor" just secret-edit "{{ file }}"
    echo "Wrote {{ file }} - run 'just secret-rekey' (YubiKey) before it can build."

[doc('Create secrets that declare a `generator` and have no file yet (no YubiKey) - follow with secret-rekey')]
[group('secret')]
secret-generate:
    #!/usr/bin/env -S bash -e
    {{ nixcmd }} run .#agenix-rekey.{{ system }}.generate
    git add -- secrets

[doc('Rekey all secrets - needed when adding secrets/hosts')]
[group('secret')]
secret-rekey:
    #!/usr/bin/env -S bash -e
    {{ nixcmd }} run .#agenix-rekey.{{ system }}.rekey
    # Stage rekeyed outputs (secrets/hosts/*/.rekey{,-hm}) + any new source secrets.
    git add -- secrets

[doc("Sets up configuration + SSH keys for a new host")]
[group('maintenance')]
new-host hostname username:
    #!/usr/bin/env -S bash -e
    if [ -d "hosts/{{ hostname }}" ]; then
        echo "Error: Host '{{ hostname }}' already exists."
        exit 1
    fi

    temp=$(mktemp -d)
    trap "rm -rf $temp" EXIT

    echo "Setting up folders"
    mkdir -p "secrets/hosts/{{ hostname }}"
    mkdir -p "hosts/{{ hostname }}"
    cat > "hosts/{{ hostname }}/host.nix" <<'EOF'
    # {{ hostname }}'s host card: the feature toggles it enables + its facts. The
    # presence of this file is what makes hosts/{{ hostname }}/ a discovered host.
    # Every host file is a card {shared?, nixos?, homeManager?}: enable features via
    # `shared.fireproof.<feature>.enable = true`, add nixos-specific settings under
    # `nixos` here or in sibling cards (e.g. system.nix), and host-specific
    # home-manager tweaks under `homeManager`.
    {
      shared = {
        fireproof.hostname = "{{ hostname }}";
        fireproof.username = "{{ username }}";
        # Enable features, e.g.:
        # fireproof.desktop.enable = true;
        # fireproof.dev.enable = true;
      };
    }
    EOF

    release=$({{ nixcmd }} eval --inputs-from . --raw nixpkgs#lib.trivial.release)
    cat > "hosts/{{ hostname }}/state-version.nix" <<EOF
    # Install-time release; never bump.
    {
      nixos.system.stateVersion = "$release";
      homeManager.home.stateVersion = "$release";
    }
    EOF

    echo "Generating SSH key for {{ username }}@{{ hostname }}"
    ssh-keygen -q -t ed25519 -f "$temp/id_ed25519" -C "{{ username }}@{{ hostname }}" -N ""
    cp "$temp/id_ed25519.pub" "secrets/hosts/{{ hostname }}/id_ed25519.pub"

    echo "Encrypting SSH key"
    just age -e "$temp/id_ed25519" -o "secrets/hosts/{{ hostname }}/id_ed25519.age"

    # Untracked files are invisible to the flake, so agenix-rekey would skip the new host.
    git add -- "hosts/{{ hostname }}" "secrets/hosts/{{ hostname }}"
    echo "Secret rekeying..."
    just secret-rekey

    echo "Host '{{ hostname }}' created and staged; it is discovered automatically (no hosts/default.nix edit needed)."
    echo "Edit hosts/{{ hostname }}/host.nix to enable features via fireproof.*.enable — see modules/base/fireproof.nix."
    echo "Add \"{{ hostname }}\" to trustedHosts in modules/system/ssh.nix so the other hosts accept its SSH key."

[doc("Update flake.lock")]
[group('maintenance')]
update input='':
    {{ nixcmd }} flake update {{ input }}

[doc('Format all files using treefmt')]
[group('maintenance')]
fmt:
    {{ nixcmd }} fmt

[doc('Run flake check to validate configuration')]
[group('maintenance')]
check:
    {{ nixcmd }} flake check

[doc('Collect garbage and delete old generations')]
[group('maintenance')]
gc days='7': (_confirm "Delete generations and store paths older than " + days + " days?")
    sudo nix-collect-garbage --delete-older-than {{ days }}d
    sudo nix-store --optimise

[doc("Run nix-tree")]
[group("tools")]
tree *ARGS=("--derivation .#nixosConfigurations." + shell("hostname -s") + ".config.system.build.toplevel"):
    nix-tree {{ ARGS }}

[doc("Run nix-diff between current system")]
[group("tools")]
diff hostname=`hostname -s`: (build-system hostname)
    nvd diff /run/current-system {{ justfile_directory() }}/result

[doc('List system generations')]
[group('tools')]
history:
    sudo nix-env -p /nix/var/nix/profiles/system --list-generations

[doc('Open nix repl with flake loaded')]
[group('tools')]
repl:
    {{ nixcmd }} repl --expr 'builtins.getFlake "path:{{ justfile_directory() }}"'

[doc("Run nurl")]
[group("tools")]
nurl *ARGS="--help":
    nurl {{ ARGS }}

[doc("Show why a package is in the closure")]
[group("tools")]
why-depends package hostname=`hostname -s`:
    {{ nixcmd }} why-depends --all .#nixosConfigurations.{{ hostname }}.config.system.build.toplevel .#nixosConfigurations.{{ hostname }}.pkgs.{{ package }}

[doc('Remove build results and temporary files')]
[group('tools')]
clean:
    rm -rf result result-*
