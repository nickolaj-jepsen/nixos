# export NIXPKGS_ALLOW_UNFREE := "1"

nixcmd := "nix --experimental-features 'nix-command flakes'"

@_default:
    just --list

[doc("Build a flake output")]
build target='':
    @{{ nixcmd }} run nixpkgs#nix-output-monitor -- build {{ justfile_directory() }}#{{ target }}

[doc('Build a nixos configuration')]
[group('deploy')]
build-system hostname:
    @just build nixosConfigurations."{{ hostname }}".config.system.build.toplevel

[doc('Wrapper for nixos-facter')]
[group('deploy')]
factor hostname=`hostname -s` target='':
    #!/usr/bin/env -S bash -e
    target="{{ target }}"
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
switch hostname=`hostname -s` target='': (build-system hostname)
    #!/usr/bin/env -S bash -e
    target="{{ target }}"
    if [ -z "$target" ]; then
        sudo {{ nixcmd }} run nixpkgs#nixos-rebuild -- switch --fast --flake .#{{ hostname }} 
    else
        {{ nixcmd }} run nixpkgs#nixos-rebuild -- switch \
            --flake .#{{ hostname }} \
            --target-host {{ target }} \
            --use-remote-sudo
    fi

[doc('Use nixos-anywhere to deploy to a remote host')]
[group('deploy')]
deploy-remote hostname target: (build-system hostname)
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
disko-install hostname disk: (build-system hostname)
    sudo {{ nixcmd }} run 'github:nix-community/disko/latest#disko-install' -- --flake .#{{ hostname }} --disk main {{ disk }}

[doc('Build an install ISO for a host')]
[group('deploy')]
iso hostname:
    {{ nixcmd }} build .#nixosConfigurations.{{ hostname }}.config.formats.install-iso

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
    {{ nixcmd }} run .#agenix-rekey.x86_64-linux.edit {{ name }}

[doc('Rekey all secrets - needed when adding secrets/hosts')]
[group('secret')]
secret-rekey:
    {{ nixcmd }} run .#agenix-rekey.x86_64-linux.rekey

[doc("Sets up configuration + SSH keys for a new host")]
new-host hostname username:
    #!/usr/bin/env -S bash -e
    temp=$(mktemp -d)
    trap "rm -rf $temp" EXIT

    echo "Setting up folders"
    mkdir -p "secrets/hosts/{{ hostname }}"
    mkdir -p "hosts/{{ hostname }}"

    echo "Generating SSH key for {{ username }}@{{ hostname }}"
    ssh-keygen -q -t ed25519 -f "$temp/id_ed25519" -C "{{ username }}@{{ hostname }}" -N ""
    cp "$temp/id_ed25519.pub" "secrets/hosts/{{ hostname }}/id_ed25519.pub"

    echo "Encrypting SSH key"
    just age -e "$temp/id_ed25519" -o "secrets/hosts/{{ hostname }}/id_ed25519.age"

    echo "Remember to update ./hosts/default.nix eg:"

    # Bold with no newline
    cat <<EOF
    {{ BOLD }}{{ hostname }} = mkSystem {
      hostname = "{{ hostname }}";
      username = "{{ username }}";
      modules = [
        ../modules/required.nix
        ../modules/shell.nix
        ../modules/graphical.nix
        ../modules/devenv.nix
      ];
    };
    EOF

[doc("Update flake.lock")]
update:
    {{ nixcmd }} flake update

[doc("Run nix-tree")]
[group("tools")]
tree *ARGS=("--derivation .#nixosConfigurations." + shell("hostname -s") + ".config.system.build.toplevel"):
    {{ nixcmd }} run github:utdemir/nix-tree -- {{ ARGS }}

[doc("Run nix-diff between current system")]
[group("tools")]
diff: build
    {{ nixcmd }} run nixpkgs#nvd -- diff /run/current-system {{ justfile_directory() }}/result

[doc("Run nurl")]
[group("tools")]
nurl *ARGS="--help":
    {{ nixcmd }} run nixpkgs#nurl -- {{ ARGS }}
