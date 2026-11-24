# Dual: nixos driver + home-manager session env, Firefox VA-API and btop tweaks.
{
  flake.modules.nixos.nvidia = {
    config,
    lib,
    options,
    ...
  }: let
    splash = config.fireproof.desktop.boot-splash.enable;
  in {
    config = lib.mkIf config.fireproof.hardware.nvidia.enable {
      hardware.graphics.enable = true;

      services.xserver.videoDrivers = ["nvidia"];

      boot.kernelModules = ["nvidia_modeset" "nvidia_drm"];

      # The splash needs the native driver from the start: drawn on simpledrm it goes black when
      # nvidia-drm takes over after the unlock. Costs ~100 MB of initrd (mostly GSP firmware).
      boot.initrd.kernelModules = lib.mkIf splash ["nvidia" "nvidia_modeset" "nvidia_drm"];
      boot.kernelParams = lib.optional splash "plymouth.use-simpledrm=0";
      hardware.facter.detected.boot.graphics.kernelModules = lib.mkIf (!splash) (
        lib.remove "nvidia" options.hardware.facter.detected.boot.graphics.kernelModules.default
      );

      hardware.nvidia = {
        open = true;
        powerManagement.enable = true;
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
      # User-manager env, not niri's: apps launched from dms.service never see niri's environment.
      systemd.user.sessionVariables = {
        "LIBVA_DRIVER_NAME" = "nvidia";
        "__GLX_VENDOR_LIBRARY_NAME" = "nvidia";
        "NVD_BACKEND" = "direct";
      };

      # Firefox ≥137 blocklists VA-API on NVIDIA; without this YouTube decodes AV1/VP9 on the CPU.
      programs.firefox.profiles.default.settings."media.hardware-video-decoding.force-enabled" = true;

      # On NVIDIA hosts use the btop build that links NVML so the GPU panel
      # (util/VRAM/temp/power) populates.
      programs.btop.package = pkgs.btop-cuda;

      # Per-process VRAM, which btop's GPU panel doesn't break down.
      home.packages = [pkgs.nvtopPackages.nvidia];
    };
  };
}
