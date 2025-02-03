[group('vm')]
vm-build:
    git add .
    echo "Building VM..."
    nix build .#vm
    echo "VM built."
    sudo chmod 777 result/nixos.qcow2
    echo "VM permissions set."

[group('vm')]
vm-reload:
    echo "Reloading VM..."
    virsh destroy nixos
    virsh start nixos
    echo "VM reloaded."

[group('vm')]
vm-switch: vm-build vm-reload

[group('vm')]
vm-init:
    virsh pool-define-as nixos dir - - - - $HOME/.local/libvirt/images/nixos
    virsh pool-build nixos
    virsh pool-start nixos
    virt-install  \
        --name nixos \
        --os-variant=nixos-24.05 \
        --memory 8192 \
        --vcpus=4,maxvcpus=8 \
        --cpu host \
        --disk result/nixos.qcow2 \
        --network user \
        --virt-type kvm \
        --import \
        --graphics spice

[group('vm')]
vm-destroy:
    virsh destroy nixos
    virsh pool-destroy nixos
    virsh pool-undefine nixos

[group('nix')]
repl:
    nix repl --show-trace ".#" nixpkgs

[group('deploy')]
deploy-gen-hw hostname target:
    nix run github:nix-community/nixos-anywhere -- \
        --flake .#{{ hostname }} \
        --target-host {{ target }} \
        --generate-hardware-config nixos-generate-config \
        ./parts/hosts/{{ hostname }}/hardware-configuration.nix

tmp_dir := "/tmp/secrets/" + uuid()

[group('deploy')]
deploy hostname target:
    #!/usr/bin/env -S bash -e
    git add .
    # username=$(nix eval --raw  .#nixosConfigurations.{{hostname}}.config.user.username)


    # Unencrypt boot secrets
    install -d -m755 {{ tmp_dir }}/etc/ssh/
    install -d -m755 {{ tmp_dir }}/run/agenix/
    just secret-echo ./secrets/hashed-user-password > {{ tmp_dir }}/run/agenix/hashed-user-password
    just secret-echo ./secrets/luks-password > {{ tmp_dir }}/luks-password
    just secret-echo ./secrets/hosts/{{ hostname }}/id_ed25519 > {{ tmp_dir }}/etc/ssh/ssh_host_ed25519_key
    cp ./secrets/hosts/{{ hostname }}/id_ed25519.pub {{ tmp_dir }}/etc/ssh/ssh_host_ed25519_key.pub
    echo "Unencrypted files:"
    find {{ tmp_dir }} -type f
    read -n 1 -p "Did age decrypt the secrets correctly? [y/n]" yn
    if [ "$yn" != "y" ]; then
        rm -rf {{ tmp_dir }}
        exit 0
    fi
    find {{ tmp_dir }} -type f -exec chmod 600 {} \;


    # Deploy
    nix run github:nix-community/nixos-anywhere -- \
        --flake .#{{ hostname }} \
        --disk-encryption-keys /luks-password {{ tmp_dir }}/luks-password \
        --extra-files {{ tmp_dir }} \
        --target-host {{ target }}

    # Clean up
    echo "Cleaning secrets..."
    rm -rf {{ tmp_dir }}

[group('deploy')]
deploy-switch hostname target:
    nix run nixpkgs#nixos-rebuild -- \
        --flake .#{{ hostname }} \
        --target-host {{ target }} \
        --use-remote-sudo \
        --verbose \
        switch

identifier := "./secrets/yubikey-identity.age"
_get_user host:
    user := nix eval --raw  .#nixosConfigurations.{{host}}.config.user.username

[group("secret")]
secret-import path:
    #!/usr/bin/env bash
    # load the file from the root system
    cat {{ path }} | nix develop --quiet --command bash -c \
        "rage -e -r -o secrets/{{ path }}.age -i {{ identifier }}"

[group('secret')]
secret-echo file:
    nix develop --quiet --command bash -c \
        "rage -d {{ file }}.age -i {{ identifier }}"

default := ""

[group('secret')]
secret-edit name=default:
    nix run .#agenix-rekey.x86_64-linux.edit {{ name }}

[group('secret')]
secret-rekey:
    nix develop --quiet --command bash -c \
        "agenix rekey"

[group('secret')]
secret-new-ssh-key hostname $USER:
    #!/usr/bin/env -S nix develop --quiet --command bash

    mkdir -p secrets/hosts/{{ hostname }}
    ssh-keygen -t ed25519 -f secrets/hosts/{{ hostname }}/id_ed25519 -C "${USER}@{{ hostname }}"
    age-plugin-yubikey -e secrets/hosts/{{ hostname }}/id_ed25519 \
        -o secrets/hosts/{{ hostname }}/id_ed25519.age
    rm secrets/hosts/{{ hostname }}/id_ed25519
