# export NIXPKGS_ALLOW_UNFREE := "1"

nixcmd := "nix --experimental-features 'nix-command flakes'"

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

[doc('Wrapper for nixos-facter')]
[group('deploy')]
factor hostname=`hostname -s` target='':
    #!/usr/bin/env -S bash -e
    target="{{ target }}"
    if [ ! -d "hosts/{{ hostname }}" ]; then
        echo "Error: Host '{{ hostname }}' does not exist in ./hosts/"
        exit 1
    fi
    if [ -z "$target" ]; then
        sudo {{ nixcmd }} run nixpkgs#nixos-facter -- -o hosts/{{ hostname }}/facter.json
    else
        {{ nixcmd }} run github:nix-community/nixos-anywhere -- \
            --flake .#{{ hostname }} \
            --target-host {{ target }} \
            --generate-hardware-config nixos-facter \
            ./hosts/{{ hostname }}/facter.json
    fi

[doc('Wrapper for nixos-rebuild switch')]
[group("deploy")]
switch hostname=`hostname -s` target='' *ARGS="":
    #!/usr/bin/env -S bash -e
    target="{{ target }}"
    if [ -z "$target" ]; then
        sudo nixos-rebuild switch --flake .#{{ hostname }} {{ ARGS }}
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

[doc('Use nixos-anywhere to deploy to a remote host')]
[group('deploy')]
deploy-remote hostname target: (_confirm "Deploy " + hostname + " to " + target + "? This will FORMAT disks on the target.")
    #!/usr/bin/env -S bash -e
    git add .

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

[doc('A wrapper disko-install')]
[group('deploy')]
disko-install hostname disk:
    sudo {{ nixcmd }} run 'github:nix-community/disko/latest#disko-install' -- --flake .#{{ hostname }} --disk main {{ disk }}

[doc('Build an install ISO for a host')]
[group('tools')]
iso hostname:
    {{ nixcmd }} build .#nixosConfigurations.{{ hostname }}.config.formats.install-iso

[doc('Generate Markdown reference for the fireproof.* options into docs/')]
[group('tools')]
docs:
    #!/usr/bin/env -S bash -e
    mkdir -p docs
    out=$({{ nixcmd }} build --no-link --print-out-paths .#fireproof-docs)
    install -m 644 "$out" docs/fireproof-options.md
    echo "Wrote docs/fireproof-options.md"

[doc('Build a host-specific bootstrap ISO with the host SSH key + repo baked in')]
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

    temp=$(mktemp -d)
    trap "rm -rf $temp" EXIT

    echo "Decrypting host SSH key (touch YubiKey if prompted)..."
    just age -d "secrets/hosts/{{ hostname }}/id_ed25519.age" > "$temp/id_ed25519"
    chmod 600 "$temp/id_ed25519"
    cp "secrets/hosts/{{ hostname }}/id_ed25519.pub" "$temp/id_ed25519.pub"

    echo "Building bootstrap ISO for {{ hostname }}..."
    just build "nixosConfigurations.bootstrap-{{ hostname }}.config.system.build.isoImage" \
        --override-input bootstrap-payload "path:$temp"
    echo "ISO built: $(ls -1 result/iso/*.iso)"

[doc('Flash a host-specific bootstrap ISO to a USB drive')]
[group('deploy')]
bootstrap-flash hostname device: (_confirm "Flash bootstrap ISO for " + hostname + " to " + device + "? This will ERASE ALL DATA on " + device + ".")
    #!/usr/bin/env -S bash -e
    if [ ! -b "{{ device }}" ]; then
        echo "Error: {{ device }} is not a block device"
        exit 1
    fi

    just bootstrap-iso {{ hostname }}

    iso_file=$(ls -1 result/iso/*.iso | head -1)
    echo "Flashing $iso_file to {{ device }}..."
    sudo dd if="$iso_file" of="{{ device }}" bs=4M status=progress oflag=sync
    echo "Done! You can now boot from {{ device }}"

[doc('Runs (r)age with yubikey identity')]
[group('secret')]
age *ARGS="--help":
    @rage {{ ARGS }} -i ./secrets/yubikey-identity.pub

[doc('Decrypt a file to stdout')]
[group('secret')]
decrypt file:
    just age -d {{ file }}

[doc('Edit an encrypted file in $EDITOR')]
[group('secret')]
secret-edit name:
    {{ nixcmd }} run .#agenix-rekey.x86_64-linux.edit-view edit {{ name }}

[doc('Rekey all secrets - needed when adding secrets/hosts')]
[group('secret')]
secret-rekey:
    {{ nixcmd }} run .#agenix-rekey.x86_64-linux.rekey

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
    # {{ hostname }}'s host card: the aspects it selects + its facts. The presence
    # of this file is what makes hosts/{{ hostname }}/ a discovered host. Every
    # host file is a card {aspects?, shared?, nixos?, homeManager?}: add
    # nixos-specific settings under `nixos` here or in sibling cards (e.g.
    # system.nix), and host-specific home-manager tweaks under `homeManager`.
    {
      aspects = [];

      shared = {
        fireproof.hostname = "{{ hostname }}";
        fireproof.username = "{{ username }}";
      };
    }
    EOF

    echo "Generating SSH key for {{ username }}@{{ hostname }}"
    ssh-keygen -q -t ed25519 -f "$temp/id_ed25519" -C "{{ username }}@{{ hostname }}" -N ""
    cp "$temp/id_ed25519.pub" "secrets/hosts/{{ hostname }}/id_ed25519.pub"

    echo "Encrypting SSH key"
    just age -e "$temp/id_ed25519" -o "secrets/hosts/{{ hostname }}/id_ed25519.age"

    echo "Secret rekeying..."
    just secret-rekey

    echo "Host '{{ hostname }}' created and discovered automatically (no hosts/default.nix edit needed)."
    echo "Edit hosts/{{ hostname }}/host.nix to choose its aspects — see aspects.nix for the bundle graph."

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
    sudo nix-env -p /nix/var/nix/profiles/system --delete-generations {{ days }}d
    sudo nix-store --optimise

[doc("Run nix-tree")]
[group("tools")]
tree *ARGS=("--derivation .#nixosConfigurations." + shell("hostname -s") + ".config.system.build.toplevel"):
    nix-tree {{ ARGS }}

[doc("Run nix-diff between current system")]
[group("tools")]
diff hostname=`hostname -s`: (build-system hostname)
    nvd diff /run/current-system {{ justfile_directory() }}/result

[doc('Show resolved aspects, bundle closure and selected leaves for a host')]
[group('tools')]
aspects hostname=`hostname -s`:
    @{{ nixcmd }} eval .#aspects.{{ hostname }}

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
    {{ nixcmd }} why-depends --all .#nixosConfigurations.{{ hostname }}.config.system.build.toplevel nixpkgs#{{ package }}

[doc('Remove build results and temporary files')]
[group('tools')]
clean:
    rm -rf result result-*
