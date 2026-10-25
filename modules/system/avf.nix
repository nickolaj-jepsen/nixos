# Guest half of an Android Virtualization Framework VM booted by the Podroid
# fork's disk-image mode: AVF's u-boot finds the image's ESP and runs
# systemd-boot, so generations and rollback work as on any EFI host.
# `nix build .#nixosConfigurations.<h>.config.system.build.avfImage.<build-system>`.
{inputs, ...}: {
  flake.modules.nixos.avf = {
    config,
    lib,
    pkgs,
    extendModules,
    modulesPath,
    ...
  }: let
    # Mirrors systemd-boot-builder.py's copy_from_file naming, so the first
    # `switch` adopts generation 1's files instead of leaving strays behind.
    efiName = path: builtins.unsafeDiscardStringContext "/EFI/nixos/${baseNameOf (dirOf path)}-${baseNameOf path}.efi";

    # extendModules keeps nixpkgs' repart module (it sets system.build.image
    # unconditionally) out of every other host's eval.
    image =
      (extendModules {
        modules = [
          (modulesPath + "/image/repart.nix")
          ({config, ...}: let
            inherit (config.system.build) toplevel;
            kernel = "${config.boot.kernelPackages.kernel}/${config.system.boot.loader.kernelFile}";
            initrd = "${config.system.build.initialRamdisk}/${config.system.boot.loader.initrdFile}";
            efiArch = pkgs.stdenv.hostPlatform.efiArch;
          in {
            image.repart = {
              name = "${config.networking.hostName}-avf";
              sectorSize = 512;
              partitions = {
                "10-esp" = {
                  contents = {
                    # bootctl's layout: u-boot runs the removable path; `bootctl status`
                    # (the switch-time update check) only counts the EFI/systemd copy.
                    "/EFI/BOOT/BOOT${lib.toUpper efiArch}.EFI".source = "${pkgs.systemd}/lib/systemd/boot/efi/systemd-boot${efiArch}.efi";
                    "/EFI/systemd/systemd-boot${efiArch}.efi".source = "${pkgs.systemd}/lib/systemd/boot/efi/systemd-boot${efiArch}.efi";
                    ${efiName kernel}.source = kernel;
                    ${efiName initrd}.source = initrd;
                    "/loader/loader.conf".source = pkgs.writeText "loader.conf" ''
                      timeout ${toString config.boot.loader.timeout}
                      default nixos-generation-1.conf
                    '';
                    "/loader/entries/nixos-generation-1.conf".source = pkgs.writeText "nixos-generation-1.conf" ''
                      title NixOS
                      version Generation 1
                      linux ${efiName kernel}
                      initrd ${efiName initrd}
                      options init=${toplevel}/init ${toString config.boot.kernelParams}
                    '';
                  };
                  repartConfig = {
                    Type = "esp";
                    Format = "vfat";
                    Label = "ESP";
                    # Room for several generations' kernel + initrd.
                    SizeMinBytes = "512M";
                  };
                };
                "20-root" = {
                  storePaths = [toplevel];
                  contents."/nix-path-registration".source = "${pkgs.closureInfo {rootPaths = [toplevel];}}/registration";
                  repartConfig = {
                    Type = "root";
                    Format = "ext4";
                    Label = "nixos";
                    Minimize = "guess";
                  };
                };
              };
            };
          })
        ];
      })
      .config
      .system
      .build
      .image;

    # The same image assembled by another system's tools: systemd-repart needs
    # `unshare --map-root-user`, which fails under multithreaded qemu-user, so
    # a binfmt host must assemble it natively.
    imageArgs = removeAttrs (lib.functionArgs (import (modulesPath + "/image/repart-image.nix"))) [
      "name"
      "version"
      "baseName"
      "compression"
      "fileSystems"
      "finalPartitions"
      "split"
      "seed"
      "definitionsDirectory"
      "imageSize"
      "sectorSize"
      "mkfsEnv"
      "createEmpty"
    ];
    imageBuiltOn = system:
      (image.override (lib.intersectAttrs imageArgs inputs.nixpkgs.legacyPackages.${system})).overrideAttrs {
        # The override's stdenv sets --architecture, which picks the root partition's GPT type.
        inherit (image) systemdRepartFlags;
        # CopyFiles= follows a store path that is itself a symlink and copies its target.
        postPatch = ''
          chmod u+w $finalRepartDefinitions/
          for conf in $finalRepartDefinitions/*.conf; do
            links=$(sed -n 's|^CopyFiles=\(/nix/store/[^:]*\).*|\1|p' "$conf" | while read -r p; do if [ -L "$p" ]; then echo "$p"; fi; done)
            for p in $links; do
              sed -i "s|^CopyFiles=$p\(:$p\)\?\$|MakeSymlinks=$p:$(readlink "$p")|" "$conf"
            done
          done
        '';
      };
  in {
    imports = [inputs.podroid.nixosModules.guest];

    options.system.build.avfImage = lib.mkOption {
      type = lib.types.attrsOf lib.types.package;
      readOnly = true;
      description = "Raw GPT disk image for the Podroid fork's disk-image mode, keyed by the system that assembles it.";
    };

    config = lib.mkIf config.fireproof.avf.enable {
      system.build.avfImage = lib.genAttrs ["aarch64-linux" "x86_64-linux"] imageBuiltOn;

      fileSystems."/" = {
        device = "/dev/disk/by-label/nixos";
        fsType = "ext4";
        # The app grows the image file to the configured storage size.
        autoResize = true;
      };
      fileSystems."/boot" = {
        device = "/dev/disk/by-label/ESP";
        fsType = "vfat";
        options = ["umask=0077"];
      };
      boot.growPartition = true;

      # u-boot's EFI variables don't persist; systemd-boot lives at the removable path.
      boot.loader.efi.canTouchEfiVariables = false;
      boot.loader.timeout = 1;
      boot.kernelPackages = pkgs.linuxPackagesFor pkgs.avf-kernel;
      # The defaults name PC storage/USB drivers this kernel doesn't ship; virtio is built in.
      boot.initrd.includeDefaultModules = false;
      # Other modules still ask for drivers (tpm-crb, …) this fixed kernel lacks.
      boot.initrd.allowMissingModules = true;
      boot.initrd.availableKernelModules = ["virtio_pci" "virtio_blk"];
      # hvc0 console and getty, the vsock agent, and the boot-stage lines the app waits for.
      podroid.guest.enable = true;
      boot.kernelParams = [
        # Pixel 8 Pro's hypervisor advertises MPAM but traps MPAMIDR_EL1: an
        # oops in init_cpu_features at t=0 under the match_host topology.
        "arm64.nompam"
      ];

      # The app's terminal is the hvc0 console; the phone's lock screen is the gate.
      services.getty.autologinUser = config.fireproof.username;

      # The image ships an unregistered store; register it once, like sd-image.
      # Early boot: nix-daemon.socket is part of sockets.target, before basic.target.
      systemd.services.avf-first-boot = {
        wantedBy = ["sysinit.target"];
        before = ["sysinit.target" "shutdown.target" "nix-daemon.socket" "nix-daemon.service"];
        after = ["local-fs.target"];
        conflicts = ["shutdown.target"];
        unitConfig = {
          DefaultDependencies = false;
          ConditionPathExists = "/nix-path-registration";
        };
        restartIfChanged = false;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          ${lib.getExe' config.nix.package.out "nix-store"} --load-db < /nix-path-registration
          touch /etc/NIXOS
          ${lib.getExe' config.nix.package.out "nix-env"} -p /nix/var/nix/profiles/system --set /run/current-system
          rm -f /nix-path-registration
        '';
      };
    };
  };
}
