{
  config,
  lib,
  fpLib,
  ...
}:
lib.mkIf config.fireproof.homelab.enable (let
  domain = "jellyfin.nickolaj.com";
in {
  services.restic.backups.homelab.paths = [config.services.jellyfin.dataDir];

  services.nginx.virtualHosts."${domain}" = fpLib.mkVirtualHost {
    port = 8096;
    websockets = true;
    http2 = true;
  };

  # Grant the media user access to GPU devices for hardware transcoding
  users.users.media.extraGroups = ["video" "render"];

  # Set VAAPI driver for Jellyfin's FFmpeg
  systemd.services.jellyfin.environment = {
    LIBVA_DRIVER_NAME = "nvidia";
    NVD_BACKEND = "direct";
  };

  services.jellyfin = {
    enable = true;
    openFirewall = true;
    user = "media";
    group = "media";
  };
})
