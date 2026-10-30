# The physical dual-boot Windows install as an on-demand libvirt VM, booted from
# the same disk as the bare-metal boot. `start-windows` starts it and opens the
# console; the prepare hook refuses to start while the host could corrupt NTFS.
{inputs, ...}: {
  flake.modules.nixos.windows-vm = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.fireproof.desktop.windows-vm;
    name = "windows";
    connection = "qemu:///system";
    espImage = "/var/lib/libvirt/images/${name}-esp.img";
    disks = [cfg.disk] ++ cfg.extraDisks;

    # Hyper-V on the real BCD (WSL2) bugchecks under KVM's nested virtualization, so the VM
    # boots a copy of the ESP whose default entry has hypervisorlaunchtype Off. Rebuilt on
    # every start: a Windows update that rewrites the BCD is picked up, never edited in place.
    prepare = pkgs.writeShellApplication {
      name = "${name}-vm-prepare";
      runtimeInputs = with pkgs; [coreutils gawk util-linux psmisc ntfs3g hivex mtools];
      text = ''
        [ "$1" = ${name} ] && [ "$2" = prepare ] || exit 0
        fail() {
          echo "${name}-vm: $*" >&2
          exit 1
        }

        for disk in ${lib.escapeShellArgs disks}; do
          dev=$(readlink -e "$disk") || fail "$disk is missing"
          # Two writers on one NTFS volume corrupt it: refuse host mounts and other openers.
          for part in $(lsblk -nrpo NAME "$dev"); do
            mnt=$(findmnt -nro TARGET -S "$part") && fail "$part is mounted at $mnt"
            [ "$(lsblk -ndo FSTYPE "$part")" = ntfs ] || continue
            # Exit 14: hibernated (Fast Startup) or unclean. Resuming either on other hardware loses data.
            ntfs-3g.probe --readwrite "$part" >/dev/null 2>&1 \
              || fail "$part is hibernated or unclean (ntfs-3g.probe exit $?); boot Windows natively once and shut it down"
          done
          if fuser -s "$dev" 2>/dev/null; then fail "$dev is open in another process"; fi
        done

        windows=$(readlink -e ${lib.escapeShellArg cfg.disk})
        esp=$(lsblk -nrpo NAME,PARTTYPE "$windows" | awk '$2 == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" { print $1 }')
        [ -n "$esp" ] || fail "no EFI system partition on $windows"

        work=$(mktemp -d)
        trap 'rm -rf "$work"' EXIT
        export MTOOLS_SKIP_CHECK=1
        dd if="$esp" of="$work/esp.fat" bs=4M status=none
        mcopy -o -i "$work/esp.fat" ::/EFI/Microsoft/Boot/BCD "$work/BCD"

        # 23000003 on {bootmgr} names the default entry; 250000f0 is its hypervisorlaunchtype.
        default=$(hivexsh "$work/BCD" <<'EOF'
        cd \Objects\{9dea862c-5cdd-4e70-acc1-f32b344d4795}\Elements\23000003
        lsval Element
        EOF
        )
        elements="\\Objects\\$default\\Elements"
        if ! printf 'cd %s\\250000f0\n' "$elements" | hivexsh "$work/BCD" 2>/dev/null; then
          printf 'cd %s\nadd 250000f0\ncommit\n' "$elements" | hivexsh -w "$work/BCD"
        fi
        printf 'cd %s\\250000f0\nsetval 1\nElement\nhex:3:00,00,00,00,00,00,00,00\ncommit\n' "$elements" \
          | hivexsh -w "$work/BCD"
        mcopy -o -i "$work/esp.fat" "$work/BCD" ::/EFI/Microsoft/Boot/BCD

        # A GPT disk around the FAT image, with 1 MiB of room at either end.
        size=$(stat -c %s "$work/esp.fat")
        mkdir -p "$(dirname ${espImage})"
        rm -f ${espImage}.tmp
        truncate -s $((size + 2 * 1024 * 1024)) ${espImage}.tmp
        printf 'label: gpt\nstart=2048, size=%d, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B\n' $((size / 512)) \
          | sfdisk -q ${espImage}.tmp
        dd if="$work/esp.fat" of=${espImage}.tmp bs=512 seek=2048 conv=notrunc status=none
        mv ${espImage}.tmp ${espImage}
      '';
    };

    # Each disk needs a boot order: OVMF connects only the devices it lists, and winload then
    # can't find C: (0xc000000e).
    blockDisk = i: path: ''
      <disk type="block" device="disk">
        <driver name="qemu" type="raw" cache="none" io="native" discard="unmap"/>
        <source dev="${path}"/>
        <target dev="sd${lib.elemAt ["b" "c" "d" "e" "f"] i}" bus="sata"/>
        <boot order="${toString (i + 3)}"/>
      </disk>
    '';

    domain = pkgs.writeText "${name}.xml" ''
      <domain type="kvm">
        <name>${name}</name>
        <uuid>98c332fe-c76f-4d1b-b980-27aa990559b7</uuid>
        <memory unit="GiB">12</memory>
        <currentMemory unit="GiB">12</currentMemory>
        <vcpu placement="static">8</vcpu>
        <os firmware="efi">
          <type arch="x86_64" machine="q35">hvm</type>
          <firmware>
            <feature enabled="no" name="secure-boot"/>
            <feature enabled="no" name="enrolled-keys"/>
          </firmware>
          <!-- The host's vendor, model and serial; the UUID stays the domain's own. -->
          <smbios mode="host"/>
        </os>
        <features>
          <acpi/>
          <apic/>
          <hyperv mode="custom">
            <relaxed state="on"/>
            <vapic state="on"/>
            <spinlocks state="on" retries="8191"/>
            <vpindex state="on"/>
            <runtime state="on"/>
            <synic state="on"/>
            <stimer state="on"><direct state="on"/></stimer>
            <frequencies state="on"/>
            <reenlightenment state="on"/>
            <tlbflush state="on"><direct state="on"/><extended state="on"/></tlbflush>
            <ipi state="on"/>
            <evmcs state="on"/>
            <emsr_bitmap state="on"/>
            <xmm_input state="on"/>
          </hyperv>
          <vmport state="off"/>
        </features>
        <cpu mode="host-passthrough" check="none" migratable="off">
          <topology sockets="1" dies="1" cores="4" threads="2"/>
        </cpu>
        <!-- Windows keeps the RTC in local time on this dual-boot machine. -->
        <clock offset="localtime">
          <timer name="rtc" tickpolicy="catchup"/>
          <timer name="pit" tickpolicy="delay"/>
          <timer name="hpet" present="no"/>
          <timer name="hypervclock" present="yes"/>
        </clock>
        <on_poweroff>destroy</on_poweroff>
        <on_reboot>restart</on_reboot>
        <on_crash>destroy</on_crash>
        <pm>
          <suspend-to-mem enabled="no"/>
          <suspend-to-disk enabled="no"/>
        </pm>
        <devices>
          <disk type="file" device="disk">
            <driver name="qemu" type="raw"/>
            <source file="${espImage}"/>
            <target dev="sda" bus="sata"/>
            <boot order="1"/>
          </disk>
          <!-- Emulated NVMe, like the real disk: Windows boots on the stornvme driver it already has. -->
          <controller type="nvme" index="0">
            <serial>WINVM0001</serial>
          </controller>
          <disk type="block" device="disk">
            <driver name="qemu" type="raw" cache="none" io="native" discard="unmap"/>
            <source dev="${cfg.disk}"/>
            <target dev="nvme0n1" bus="nvme"/>
            <boot order="2"/>
          </disk>
          ${lib.concatImapStrings (i: blockDisk (i - 1)) cfg.extraDisks}
          <controller type="usb" model="qemu-xhci"/>
          <controller type="virtio-serial"/>
          <interface type="network">
            <source network="default"/>
            <model type="e1000e"/>
          </interface>
          <channel type="unix">
            <target type="virtio" name="org.qemu.guest_agent.0"/>
          </channel>
          <channel type="spicevmc">
            <target type="virtio" name="com.redhat.spice.0"/>
          </channel>
          <input type="tablet" bus="usb"/>
          <graphics type="spice">
            <listen type="none"/>
            <image compression="off"/>
          </graphics>
          <video>
            <model type="qxl" primary="yes"/>
          </video>
          <sound model="ich9"/>
          <audio id="1" type="spice"/>
          <memballoon model="virtio"/>
        </devices>
      </domain>
    '';

    # Validated against libvirt's schema at build time, so a typo fails `just build`, not `virsh start`.
    definition = pkgs.runCommand "${name}-domain.xml" {nativeBuildInputs = [config.virtualisation.libvirtd.package pkgs.libxml2];} ''
      virt-xml-validate ${domain} domain
      cp ${domain} $out
    '';

    startWindows = pkgs.writeShellApplication {
      name = "start-windows";
      runtimeInputs = [config.virtualisation.libvirtd.package pkgs.virt-manager pkgs.libnotify];
      text = ''
        export LIBVIRT_DEFAULT_URI=${connection}
        if [ "$(virsh domstate ${name})" != running ] && ! out=$(virsh start ${name} 2>&1); then
          # Launched from the app launcher, a refusal from the prepare hook would vanish unseen.
          # libvirt prefixes the hook's own line with the hook's whole environment; show only the line.
          reason=$(grep -o '${name}-vm: .*' <<<"$out" || echo "$out")
          notify-send -u critical "Windows VM did not start" "$reason"
          echo "$out" >&2
          exit 1
        fi
        exec virt-manager --connect ${connection} --show-domain-console ${name}
      '';
    };
  in {
    imports = [inputs.nixvirt.nixosModules.default];

    config = lib.mkIf cfg.enable {
      virtualisation.libvirt = {
        enable = true;
        connections.${connection} = {
          # restart = false: a switch while Windows runs updates the definition for its next start
          # instead of powering it off.
          domains = [
            {
              inherit definition;
              restart = false;
            }
          ];
          networks = [
            {
              definition = inputs.nixvirt.lib.network.writeXML (inputs.nixvirt.lib.network.templates.bridge {
                uuid = "4d5dd3bf-36ad-4c0f-a6c6-0e7a4d0f5c55";
                subnet_byte = 122;
              });
              active = true;
            }
          ];
        };
      };

      virtualisation.libvirtd = {
        qemu.package = pkgs.qemu_kvm;
        hooks.qemu."${name}-vm" = lib.getExe prepare;
        onBoot = "ignore";
        # libvirt-guests asks Windows to shut down when the host does, then powers it off.
        onShutdown = "shutdown";
        shutdownTimeout = 120;
      };

      # dnsmasq on the NAT bridge hands out the guest's address; the host firewall would drop it.
      networking.firewall.trustedInterfaces = ["virbr0"];

      # Desktop automount must never offer the Windows partitions while the VM may own them.
      services.udev.extraRules =
        lib.concatMapStrings (disk: ''
          SUBSYSTEM=="block", ENV{DEVTYPE}=="partition", SYMLINK=="${lib.removePrefix "/dev/" disk}-part*", ENV{UDISKS_IGNORE}="1"
        '')
        disks;

      programs.virt-manager.enable = true;
      users.users.${config.fireproof.username}.extraGroups = ["libvirtd"];

      environment.systemPackages = [
        startWindows
        (pkgs.makeDesktopItem {
          name = "start-windows";
          desktopName = "Windows";
          comment = "Boot the Windows install in a VM";
          exec = "start-windows";
          icon = "virt-manager";
          categories = ["System"];
        })
      ];
    };
  };
}
