{
  flake.modules.nixos.beszel = {
    config,
    lib,
    fpLib,
    ...
  }: let
    cfg = config.fireproof.homelab;
    domain = "beszel.${cfg.domain}";
    port = 8091;
  in {
    config = lib.mkIf config.fireproof.homelab.enable {
      services.restic.backups.homelab.paths = ["/var/lib/beszel-hub"];

      services.oauth2-proxy.nginx.virtualHosts."${domain}".allowed_groups = ["default"];

      services.nginx.virtualHosts."${domain}" = fpLib.mkVirtualHost {
        inherit port;
        websockets = true; # PocketBase realtime
      };

      services.beszel.hub = {
        enable = true;
        host = "127.0.0.1";
        inherit port;
        # oauth2-proxy is the gate; trust its X-Email (nginx strips client-supplied, hub is loopback-only) to skip Beszel login and auto-provision the SSO user.
        environment = {
          TRUSTED_AUTH_HEADER = "X-Email";
          USER_CREATION = "true";
        };
      };

      age.secrets.beszel-agent-env.rekeyFile =
        ../../secrets/hosts/homelab/beszel-agent-env.age;

      services.beszel.agent = {
        enable = true;
        environmentFile = config.age.secrets.beszel-agent-env.path;
        smartmon.enable = true;
      };
    };
  };
}
