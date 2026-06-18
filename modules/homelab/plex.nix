{
  flake.modules.nixos.plex = {
    config,
    lib,
    pkgs,
    fpLib,
    ...
  }: let
    cfg = config.fireproof.homelab;
    domain = "plex.${cfg.domain}";
  in {
    config = lib.mkIf config.fireproof.homelab.enable {
      services.nginx.virtualHosts."${domain}" = fpLib.mkVirtualHost {
        port = 32400;
        websockets = true;
        http2 = true;
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
