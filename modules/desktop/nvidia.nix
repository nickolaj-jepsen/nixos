{
  config,
  lib,
  pkgs,
  ...
}: {
  options.fireproof.hardware.nvidia.enable =
    lib.mkEnableOption "NVIDIA GPU support (open kernel module + VA-API video offload)";

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

    fireproof.home-manager.programs.niri.settings.environment = {
      "LIBVA_DRIVER_NAME" = "nvidia";
      "__GLX_VENDOR_LIBRARY_NAME" = "nvidia";
      "NVD_BACKEND" = "direct";
    };
  };
}
