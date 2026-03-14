{
  config,
  lib,
  fpLib,
  ...
}:
lib.mkIf config.fireproof.homelab.enable (let
  domain = "audiobookshelf.nickolaj.com";
  port = 8234;
in {
  services.restic.backups.homelab.paths = ["/var/lib/audiobookshelf"];

  services.nginx.virtualHosts."${domain}" = fpLib.mkVirtualHost {
    inherit port;
    websockets = true;
    http2 = true;
  };

  services.audiobookshelf = {
    enable = true;
    inherit port;
    user = "media";
    group = "media";
  };

  # Create the audiobook, ebook, and podcast directories
  systemd.tmpfiles.rules = [
    "d /mnt/data/audiobooks 0775 media media -"
    "d /mnt/data/books 0775 media media -"
    "d /mnt/data/podcasts 0775 media media -"
  ];
})
