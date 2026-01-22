{
  config,
  lib,
  pkgsUnstable,
  ...
}:
lib.mkIf config.fireproof.homelab.enable (let
  domain = "navidrome.nickolaj.com";
in {
  age.secrets.navidrome-env.rekeyFile = ../../secrets/hosts/homelab/navidrome-env.age;

  services.restic.backups.homelab.paths = ["/var/lib/navidrome"];

  services.oauth2-proxy.nginx.virtualHosts."${domain}".allowed_groups = ["default"];

  services.nginx.virtualHosts."${domain}" = {
    forceSSL = true;
    enableACME = true;
    locations."/" = {
      proxyPass = "http://localhost:4533/";
      proxyWebsockets = true;
      extraConfig = ''
        auth_request_set $email  $upstream_http_x_auth_request_email;
        proxy_set_header Remote-User $email;
      '';
    };
    locations."^~ /rest" = {
      proxyPass = "http://localhost:4533";
      proxyWebsockets = true;
      extraConfig = ''
        auth_request off;
      '';
    };
  };

  services.navidrome = {
    enable = true;
    package = pkgsUnstable.navidrome;
    user = "media";
    group = "media";
    environmentFile = config.age.secrets.navidrome-env.path;
    settings = {
      Address = "127.0.0.1";
      Port = 4533;
      MusicFolder = "/mnt/data/music";
      ScanSchedule = "@every 1m";
      LogLevel = "info";
      "ExtAuth.Enabled" = true;
      "ExtAuth.TrustedSources" = "127.0.0.1/32";
      "ExtAuth.UserHeader" = "Remote-User";
    };
  };

  systemd.tmpfiles.rules = [
    "d /mnt/data/music 0775 media media -"
    "Z /var/lib/navidrome 0750 media media -"
  ];
})
