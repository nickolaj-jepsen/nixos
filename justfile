build-vm:
    @git add .
    echo "Building VM..."
    nix build .#nixosConfigurations.qemu.config.formats.qcow 
    echo "VM built."
    @sudo chmod 777 result/nixos.qcow2
    echo "VM permissions set."

reload-vm: build-vm
    @sleep 5
    echo "Reloading VM..."
    -virsh destroy nixos
    virsh start nixos
    echo "VM reloaded."

setup-vm:
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
