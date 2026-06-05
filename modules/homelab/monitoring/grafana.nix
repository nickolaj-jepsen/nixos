# Grafana for the monitoring hub.
#
# Sits behind oauth2-proxy/Zitadel like the other homelab apps, so its own login
# form is disabled and an authenticated request is treated as Admin. Datasource
# and dashboards are provisioned from this repo - nothing lives only in the UI.
{
  config,
  lib,
  pkgs,
  fpLib,
  ...
}: let
  cfg = config.fireproof.monitoring;
  domain = "grafana.${cfg.domain}";
  port = 3000;

  # Dashboards defined as Nix -> JSON. Drop more files in ./dashboards and add
  # them here; community dashboards can be committed as exported JSON too.
  dashboards = pkgs.linkFarm "grafana-dashboards" [
    {
      name = "fleet-overview.json";
      path = pkgs.writeText "fleet-overview.json" (builtins.toJSON (import ./dashboards/fleet.nix));
    }
  ];
in {
  config = lib.mkIf cfg.server.enable {
    services.oauth2-proxy.nginx.virtualHosts."${domain}" = {};

    services.nginx.virtualHosts."${domain}" = fpLib.mkVirtualHost {
      inherit port;
      websockets = true;
    };

    services.grafana = {
      enable = true;
      settings = {
        server = {
          http_addr = "127.0.0.1";
          http_port = port;
          inherit domain;
          root_url = "https://${domain}/";
        };
        analytics = {
          reporting_enabled = false;
          check_for_updates = false;
        };
        users.allow_sign_up = false;
        # oauth2-proxy already authenticated the request at the edge.
        "auth.anonymous" = {
          enabled = true;
          org_role = "Admin";
        };
        auth = {
          disable_login_form = true;
          disable_signout_menu = true;
        };
      };

      provision = {
        enable = true;
        datasources.settings = {
          apiVersion = 1;
          datasources = [
            {
              name = "Prometheus";
              type = "prometheus";
              uid = "prometheus";
              access = "proxy";
              url = "http://127.0.0.1:${toString config.services.prometheus.port}";
              isDefault = true;
            }
          ];
        };
        dashboards.settings = {
          apiVersion = 1;
          providers = [
            {
              name = "nixos";
              options.path = "${dashboards}";
              options.foldersFromFilesStructure = true;
            }
          ];
        };
      };
    };
  };
}
