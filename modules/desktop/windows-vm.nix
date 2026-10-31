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
    images = "/var/lib/libvirt/images";
    espImage = "${images}/${name}-esp.img";
    # The guest's partition table; its head and tail are the only writable non-Windows sectors.
    gptImage = "${images}/${name}-gpt.img";
    mapper = "${name}-vm";

    # The guest gets a same-size disk built with dm: a synthetic GPT listing only the Windows
    # partitions (same disk and partition GUIDs, so the BCD resolves), those partitions at
    # their real offsets, a rebuilt ESP copy, and zeros everywhere else. Linux partitions on
    # the same disk are never mapped.
    hook = pkgs.writeShellApplication {
      name = "${name}-vm-hook";
      runtimeInputs = with pkgs; [coreutils gawk gnugrep util-linux psmisc ntfs3g hivex mtools dosfstools lvm2];
      text = ''
        [ "$1" = ${name} ] || exit 0
        teardown() {
          if dmsetup info ${mapper} >/dev/null 2>&1; then dmsetup remove ${mapper}; fi
          for image in ${espImage} ${gptImage}; do
            for loop in $(losetup -nO NAME -j "$image"); do losetup -d "$loop"; done
          done
        }
        fail() {
          echo "${name}-vm: $*" >&2
          teardown
          exit 1
        }
        # The sectors only the synthetic GPT occupies: everything before the first partition, and
        # the backup table.
        gpt_sum() {
          { head -c $(($1 * 512)) ${gptImage}; tail -c $((33 * 512)) ${gptImage}; } | sha256sum | cut -d' ' -f1
        }
        case "$2" in
          prepare) ;;
          release)
            teardown
            exit 0
            ;;
          *) exit 0 ;;
        esac
        # A crash may have left the previous run's mapping behind.
        teardown

        windows=$(readlink -e ${lib.escapeShellArg cfg.disk}) || fail "${cfg.disk} is missing"
        disk_sectors=$(cat "/sys/class/block/$(basename "$windows")/size")
        part_of() {
          local dev
          dev=$(lsblk -nrpo NAME,PARTUUID "$windows" | awk -v u="$1" '$2 == u { print $1 }')
          [ -n "$dev" ] || fail "no partition $1 on $windows; did the partition table change?"
          echo "$dev"
        }

        # Two writers on one NTFS volume corrupt it: refuse host mounts, holders and other openers.
        check_free() {
          local mnt
          mnt=$(findmnt -nro TARGET -S "$1") && fail "$1 is mounted at $mnt"
          [ -z "$(ls "/sys/class/block/$(basename "$1")/holders")" ] || fail "$1 is held by another device"
          if fuser -s "$1" 2>/dev/null; then fail "$1 is open in another process"; fi
          [ "$(lsblk -ndo FSTYPE "$1")" = ntfs ] || return 0
          # Exit 14: hibernated (Fast Startup) or unclean. Resuming either on other hardware loses data.
          ntfs-3g.probe --readwrite "$1" >/dev/null 2>&1 \
            || fail "$1 is hibernated or unclean (ntfs-3g.probe exit $?); boot Windows natively once and shut it down"
        }

        # name start sectors device: the regions the guest sees, by offset.
        regions=$(mktemp)
        work=$(mktemp -d)
        trap 'rm -rf "$work" "$regions"' EXIT
        for uuid in ${lib.escapeShellArgs cfg.partitions}; do
          part=$(part_of "$uuid")
          case "$(lsblk -ndo PARTTYPE "$part")" in
            ebd0a0a2-b9e5-4433-87c0-68b6b72699c7 | de94bba4-06d1-4d40-a16a-bfd50179d6ac) ;;
            *) fail "$part ($uuid) is not a Windows data or recovery partition" ;;
          esac
          check_free "$part"
          sys="/sys/class/block/$(basename "$part")"
          echo "$uuid $(cat "$sys/start") $(cat "$sys/size") $part" >>"$regions"
        done
        extra_disks=(${lib.escapeShellArgs cfg.extraDisks})
        for disk in "''${extra_disks[@]}"; do
          dev=$(readlink -e "$disk") || fail "$disk is missing"
          # lsblk lists the whole disk first, then its partitions.
          for part in $(lsblk -nrpo NAME "$dev"); do check_free "$part"; done
        done

        # The guest may only change its partition table natively: a VM-side resize (a WinRE
        # update, Disk Management) would never reach the real disk.
        if [ -e ${gptImage}.sum ]; then
          read -r last_first last_sum <${gptImage}.sum
          [ "$(gpt_sum "$last_first")" = "$last_sum" ] \
            || fail "the guest changed its partition table since the last start; make partition changes in native Windows, then delete ${gptImage}.sum"
        fi

        # Hyper-V on the real BCD (WSL2) bugchecks under KVM's nested virtualization, so the VM
        # boots a copy of the ESP whose default entry has hypervisorlaunchtype Off. Rebuilt on
        # every start: a Windows update that rewrites the BCD is picked up, never edited in place.
        esp=$(part_of ${lib.escapeShellArg cfg.esp})
        esp_mnt=$(findmnt -nro TARGET -S "$esp") || fail "$esp (the ESP) is not mounted"
        esp_sys="/sys/class/block/$(basename "$esp")"
        esp_start=$(cat "$esp_sys/start")
        esp_sectors=$(cat "$esp_sys/size")
        export MTOOLS_SKIP_CHECK=1
        cp "$esp_mnt/EFI/Microsoft/Boot/BCD" "$work/BCD"
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
        mkdir -p ${images}
        rm -f ${espImage}
        truncate -s $((esp_sectors * 512)) ${espImage}
        mkfs.fat -F 32 -n SYSTEM ${espImage} >/dev/null
        mmd -i ${espImage} ::/EFI ::/EFI/Boot
        mcopy -s -i ${espImage} "$esp_mnt/EFI/Microsoft" ::/EFI/
        mcopy -o -i ${espImage} "$work/BCD" ::/EFI/Microsoft/Boot/BCD
        # The fallback path, so OVMF boots Windows without NVRAM entries; the host's loader stays out.
        mcopy -i ${espImage} "$esp_mnt/EFI/Microsoft/Boot/bootmgfw.efi" ::/EFI/Boot/bootx64.efi
        echo "${cfg.esp} $esp_start $esp_sectors image" >>"$regions"
        sort -n -k2 -o "$regions" "$regions"

        # The real table's header and the guest's partitions' lines, verbatim: same offsets,
        # GUIDs, types, names and attributes.
        rm -f ${gptImage}
        truncate -s $((disk_sectors * 512)) ${gptImage}
        sfdisk -d "$windows" \
          | awk -v keep="$(awk '{ print toupper($1) }' "$regions" | paste -sd,)" '
              BEGIN { n = split(keep, k, ","); for (i = 1; i <= n; i++) want[k[i]] = 1 }
              /^(label|label-id|unit|sector-size):/ { print; next }
              match(toupper($0), /UUID=[0-9A-F-]+/) && (substr(toupper($0), RSTART + 5, RLENGTH - 5) in want) { print }
            ' \
          | sfdisk -q --no-reread --no-tell-kernel ${gptImage}
        first=$(awk 'NR == 1 { print $2 }' "$regions")

        gpt_loop=$(losetup --find --show ${gptImage})
        esp_loop=$(losetup --find --show ${espImage})
        table="0 $first linear $gpt_loop 0"$'\n'
        cursor=$first
        while read -r _ start sectors dev; do
          [ "$start" -ge "$cursor" ] || fail "partitions overlap at sector $start"
          [ "$start" -eq "$cursor" ] || table+="$cursor $((start - cursor)) zero"$'\n'
          [ "$dev" != image ] || dev=$esp_loop
          table+="$start $sectors linear $dev 0"$'\n'
          cursor=$((start + sectors))
        done <"$regions"
        tail_start=$((disk_sectors - 33))
        [ "$cursor" -le "$tail_start" ] || fail "partitions reach into the backup GPT"
        [ "$cursor" -eq "$tail_start" ] || table+="$cursor $((tail_start - cursor)) zero"$'\n'
        table+="$tail_start 33 linear $gpt_loop $tail_start"
        printf '%s\n' "$table" | dmsetup create ${mapper}
        echo "$first $(gpt_sum "$first")" >${gptImage}.sum
      '';
    };

    # Each disk needs a boot order: OVMF connects only the devices it lists, and winload then
    # can't find C: (0xc000000e).
    blockDisk = i: path: ''
      <disk type="block" device="disk">
        <driver name="qemu" type="raw" cache="none" io="native" discard="unmap"/>
        <source dev="${path}"/>
        <target dev="sd${lib.elemAt ["b" "c" "d" "e" "f"] i}" bus="sata"/>
        <boot order="${toString (i + 2)}"/>
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
          <!-- Emulated NVMe, like the real disk: Windows boots on the stornvme driver it already has. -->
          <controller type="nvme" index="0">
            <serial>WINVM0001</serial>
          </controller>
          <disk type="block" device="disk">
            <driver name="qemu" type="raw" cache="none" io="native" discard="unmap"/>
            <source dev="/dev/mapper/${mapper}"/>
            <target dev="nvme0n1" bus="nvme"/>
            <boot order="1"/>
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
        hooks.qemu."${name}-vm" = lib.getExe hook;
        onBoot = "ignore";
        # libvirt-guests asks Windows to shut down when the host does, then powers it off.
        onShutdown = "shutdown";
        shutdownTimeout = 120;
      };

      # dnsmasq on the NAT bridge hands out the guest's address; the host firewall would drop it.
      networking.firewall.trustedInterfaces = ["virbr0"];

      # Desktop automount must never offer the Windows partitions, or the guest's disk, while the VM may own them.
      services.udev.extraRules =
        lib.concatMapStrings (disk: ''
          SUBSYSTEM=="block", ENV{DEVTYPE}=="partition", SYMLINK=="${lib.removePrefix "/dev/" disk}-part*", ENV{UDISKS_IGNORE}="1"
        '') ([cfg.disk] ++ cfg.extraDisks)
        + ''
          SUBSYSTEM=="block", ENV{DM_NAME}=="${mapper}", ENV{UDISKS_IGNORE}="1"
        '';

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
