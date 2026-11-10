# Throwaway QEMU desktop for trying the Hyprland session: `nix run .#hyprland-vm`.
# A package rather than a host, so it needs no host key, no rekey and no place in CI's host matrix.
{
  config,
  inputs,
  ...
}: let
  username = "nickolaj";

  # secrets/hosts/hyprland-vm only holds a placeholder key agenix-rekey insists on reading; nothing is encrypted to it.
  noSecrets = {lib, ...}: {age.secrets = lib.mkForce {};};

  vm = config.flake.mkNixos {
    shared = [
      noSecrets
      {
        fireproof = {
          inherit username;
          hostname = "hyprland-vm";
          tailscale.enable = false;
          desktop.enable = true;
          desktop.hyprland.enable = true;
          desktop.autologin.enable = true;
          desktop.obsidian-livesync.enable = false;
          monitors = [{name = "Virtual-1";}];
        };
      }
    ];
    homeManagerModules = [
      ({
        lib,
        pkgs,
        ...
      }: {
        home.stateVersion = "26.05";
        # The guest's virtual GPU can't give ghostty the GL context it asks for.
        programs.ghostty.package = lib.mkForce (pkgs.symlinkJoin {
          name = "ghostty";
          paths = [pkgs.unstable.ghostty];
          nativeBuildInputs = [pkgs.makeWrapper];
          postBuild = "wrapProgram $out/bin/ghostty --set LIBGL_ALWAYS_SOFTWARE 1";
          meta.mainProgram = "ghostty";
        });
      })
    ];
    nixosModules = [
      "${inputs.nixpkgs}/nixos/modules/virtualisation/qemu-vm.nix"
      ({
        lib,
        pkgs,
        ...
      }: {
        system.stateVersion = "26.05";
        users.users.${username} = {
          hashedPasswordFile = lib.mkForce null;
          initialPassword = "vm";
        };

        virtualisation = {
          cores = 4;
          memorySize = 8192;
          diskSize = 8192;
          qemu.options = [
            "-vga none"
            "-device virtio-vga-gl,xres=1920,yres=1080"
            "-display \${HYPRLAND_VM_DISPLAY:-gtk,gl=on}"
          ];
        };

        environment.systemPackages = [pkgs.foot];
      })
    ];
  };
in {
  perSystem = {
    pkgs,
    system,
    ...
  }: {
    packages = inputs.nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
      hyprland-vm = pkgs.writeShellApplication {
        name = "hyprland-vm";
        text = ''
          # The desktop session's alsa-lib path drags a mismatched glibc into qemu.
          unset LD_LIBRARY_PATH
          state=$(mktemp -d)
          trap 'rm -rf "$state"' EXIT
          export NIX_DISK_IMAGE=$state/disk.qcow2
          ${vm.config.system.build.vm}/bin/run-hyprland-vm-vm "$@"
        '';
      };
    };
  };
}
