{fpLib, ...}: {
  flake.modules.nixos.plex = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.fireproof.homelab;
    domain = "plex.${cfg.domain}";
  in {
    config = lib.mkIf (cfg.enable && cfg.plex.enable) {
      systemd.services.plex.unitConfig.RequiresMountsFor = ["/mnt/data"];

      services.nginx.virtualHosts."${domain}" = fpLib.mkVirtualHost {
        port = 32400;
        websockets = true;
      };

      fireproof.homelab.dashboard.monitors.plex = {
        title = "Plex";
        url = "https://${domain}";
        icon = "sh:plex";
        group = "media";
        altStatusCodes = [401];
      };

      services.plex = {
        enable = true;
        package = pkgs.unstable.plex;
        openFirewall = true;
        user = "media";
        group = "media";
      };
    };
  };
}
