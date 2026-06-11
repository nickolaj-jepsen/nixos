{
  config,
  lib,
  fpLib,
  ...
}: let
  cfg = config.fireproof.homelab;
  domain = "beszel.${cfg.domain}";
  port = 8091;
in {
  config = lib.mkIf cfg.enable {
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
    };

    # ── PHASE 2: uncomment once beszel-agent-env.age contains the KEY ──
    # age.secrets.beszel-agent-env.rekeyFile =
    #   ../../secrets/hosts/homelab/beszel-agent-env.age;
    #
    # services.beszel.agent = {
    #   enable = true;
    #   environmentFile = config.age.secrets.beszel-agent-env.path;
    #   smartmon.enable = true;          # disk SMART
    #   # nvidia-smi auto-added because videoDrivers = ["nvidia"] → GPU stats
    # };
  };
}
