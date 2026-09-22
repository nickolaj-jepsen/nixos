# Dual: nixos driver + home-manager niri/btop tweaks.
{
  flake.modules.nixos.nvidia = {
    config,
    lib,
    options,
    ...
  }: {
    config = lib.mkIf config.fireproof.hardware.nvidia.enable {
      hardware.graphics.enable = true;

      services.xserver.videoDrivers = ["nvidia"];

      boot.kernelModules = ["nvidia_modeset" "nvidia_drm"];

      # facter would put nvidia in the initrd: ~90 MB of ESP per generation (mostly GSP firmware) for no early KMS.
      hardware.facter.detected.boot.graphics.kernelModules =
        lib.remove "nvidia" options.hardware.facter.detected.boot.graphics.kernelModules.default;

      hardware.nvidia = {
        open = true;
        powerManagement.enable = true;
      };

      # NVIDIA does not release VRAM back to the pool under Wayland compositors,
      # so a long-running niri session can balloon. This is the niri-documented
      # application profile that caps that growth.
      # https://github.com/YaLTeR/niri/wiki/Nvidia
      environment.etc."nvidia/nvidia-application-profiles-rc.d/50-limit-free-buffer-pool.json".text = builtins.toJSON {
        rules = [
          {
            pattern = {
              feature = "procname";
              matches = "niri";
            };
            profile = "Limit Free Buffer Pool On Wayland Compositors";
          }
        ];
        profiles = [
          {
            name = "Limit Free Buffer Pool On Wayland Compositors";
            settings = [
              {
                key = "GLVidHeapReuseRatio";
                value = 0;
              }
            ];
          }
        ];
      };
    };
  };

  flake.modules.homeManager.nvidia = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.fireproof.hardware.nvidia.enable {
      programs.niri.settings.environment = {
        "LIBVA_DRIVER_NAME" = "nvidia";
        "__GLX_VENDOR_LIBRARY_NAME" = "nvidia";
        "NVD_BACKEND" = "direct";
      };

      # btop is enabled globally in core.nix; on NVIDIA hosts use the build that
      # links NVML so the GPU panel (util/VRAM/temp/power) populates.
      programs.btop.package = pkgs.btop-cuda;

      # Per-process VRAM, which btop's GPU panel doesn't break down.
      home.packages = [pkgs.nvtopPackages.nvidia];
    };
  };
}
