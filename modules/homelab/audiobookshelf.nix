{
  config,
  lib,
  ...
}:
lib.mkIf config.fireproof.homelab.enable (let
  domain = "audiobookshelf.nickolaj.com";
  port = 8234;
in {
  services.restic.backups.homelab.paths = ["/var/lib/audiobookshelf"];

  services.nginx.virtualHosts."${domain}" = {
    forceSSL = true;
    enableACME = true;
    http2 = true;
    locations."/" = {
      proxyWebsockets = true;
      proxyPass = "http://localhost:${toString port}/";
    };
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
