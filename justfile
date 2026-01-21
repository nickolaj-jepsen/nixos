# export NIXPKGS_ALLOW_UNFREE := "1"

nixcmd := "nix --experimental-features 'nix-command flakes'"

@_default:
    just --list

[doc("Build a flake output")]
[group('tools')]
build target *ARGS="":
    @{{ nixcmd }} run {{ ARGS }} nixpkgs#nix-output-monitor -- build {{ justfile_directory() }}#{{ target }}

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
        sudo {{ nixcmd }} run nixpkgs#nixos-rebuild -- switch --show-trace --flake .#{{ hostname }} {{ ARGS }}
    else
        {{ nixcmd }} run nixpkgs#nixos-rebuild -- switch \
            --flake .#{{ hostname }} \
            --use-substitutes \
            --target-host {{ target }} \
            --sudo {{ ARGS }}
    fi

[doc('Wrapper for nixos-rebuild boot')]
[group("deploy")]
boot hostname=`hostname -s` *ARGS="":
    sudo {{ nixcmd }} run nixpkgs#nixos-rebuild -- boot --show-trace --flake .#{{ hostname }} {{ ARGS }}

[doc('Wrapper for nixos-rebuild test')]
[group("deploy")]
test hostname=`hostname -s` *ARGS="":
    sudo {{ nixcmd }} run nixpkgs#nixos-rebuild -- test --show-trace --flake .#{{ hostname }} {{ ARGS }}

[doc('Use nixos-anywhere to deploy to a remote host')]
[group('deploy')]
deploy-remote hostname target:
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

[doc('Build the bootstrap ISO for USB installation')]
[group('deploy')]
bootstrap-iso:
    @echo "Building bootstrap ISO..."
    {{ nixcmd }} build .#nixosConfigurations.bootstrap.config.system.build.isoImage
    @echo "ISO built: $(ls -1 result/iso/*.iso)"

[doc('Flash the bootstrap ISO to a USB drive')]
[group('deploy')]
bootstrap-flash device:
    #!/usr/bin/env -S bash -e
    if [ ! -b "{{ device }}" ]; then
        echo "Error: {{ device }} is not a block device"
        exit 1
    fi

    # Build the ISO first if needed
    if [ ! -d "result/iso" ]; then
        just bootstrap-iso
    fi

    iso_file=$(ls -1 result/iso/*.iso | head -1)
    echo "Flashing $iso_file to {{ device }}..."
    echo "WARNING: This will ERASE ALL DATA on {{ device }}"
    read -p "Are you sure? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        sudo dd if="$iso_file" of="{{ device }}" bs=4M status=progress oflag=sync
        echo "Done! You can now boot from {{ device }}"
    else
        echo "Aborted"
    fi

[doc('Runs (r)age with yubikey identity')]
[group('secret')]
age *ARGS="--help":
    @{{ nixcmd }} shell nixpkgs#rage nixpkgs#age-plugin-yubikey --command rage {{ ARGS }} -i ./secrets/yubikey-identity.pub

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
    cat > "hosts/{{ hostname }}/default.nix" <<'EOF'
    {
      config.fireproof.hostname = "{{ hostname }}";
      config.fireproof.username = "{{ username }}";

      imports = [];
    }
    EOF

    echo "Generating SSH key for {{ username }}@{{ hostname }}"
    ssh-keygen -q -t ed25519 -f "$temp/id_ed25519" -C "{{ username }}@{{ hostname }}" -N ""
    cp "$temp/id_ed25519.pub" "secrets/hosts/{{ hostname }}/id_ed25519.pub"

    echo "Encrypting SSH key"
    just age -e "$temp/id_ed25519" -o "secrets/hosts/{{ hostname }}/id_ed25519.age"

    echo "Secret rekeying..."
    just secret-rekey

    echo "Remember to update ./hosts/default.nix eg:"

    # Bold with no newline
    cat <<EOF
    {{ BOLD }}{{ hostname }} = mkSystem {host = ./{{ hostname }};};{{ NORMAL }}
    EOF

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
gc days='7':
    sudo nix-collect-garbage --delete-older-than {{ days }}d
    sudo nix-env -p /nix/var/nix/profiles/system --delete-older-than {{ days }}d

[doc("Run nix-tree")]
[group("tools")]
tree *ARGS=("--derivation .#nixosConfigurations." + shell("hostname -s") + ".config.system.build.toplevel"):
    {{ nixcmd }} run github:utdemir/nix-tree -- {{ ARGS }}

[doc("Run nix-diff between current system")]
[group("tools")]
diff hostname=`hostname -s`: (build-system hostname)
    {{ nixcmd }} run nixpkgs#nvd -- diff /run/current-system {{ justfile_directory() }}/result

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
    {{ nixcmd }} run nixpkgs#nurl -- {{ ARGS }}

[doc('Remove build results and temporary files')]
[group('tools')]
clean:
    rm -rf result result-*
