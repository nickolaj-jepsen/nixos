{
  config,
  lib,
  pkgs,
  ...
}: {
  config = lib.mkIf config.fireproof.hardware.nvidia.enable {
    hardware.graphics = {
      enable = true;
      # VA-API -> NVDEC bridge so Firefox/mpv can hardware-decode video.
      extraPackages = [pkgs.nvidia-vaapi-driver];
    };

    services.xserver.videoDrivers = ["nvidia"];

    hardware.nvidia = {
      open = true;
      modesetting.enable = true;
      powerManagement.enable = true;
      nvidiaSettings = true;
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

    fireproof.home-manager.programs.niri.settings.environment = {
      "LIBVA_DRIVER_NAME" = "nvidia";
      "__GLX_VENDOR_LIBRARY_NAME" = "nvidia";
      "NVD_BACKEND" = "direct";
    };

    # btop is enabled globally in core.nix; on NVIDIA hosts use the build that
    # links NVML so the GPU panel (util/VRAM/temp/power) populates.
    fireproof.home-manager.programs.btop.package = pkgs.btop-cuda;
  };
}
