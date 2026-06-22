# MCP servers, incl. grafana wrappers that source their env from a secret.
# Home-manager half only: the secrets decrypt HM-side (see secrets/hm-secrets.nix).
{
  flake.modules.homeManager.mcp = {
    config,
    lib,
    pkgs,
    ...
  }: let
    # One mcp-grafana per instance, env (GRAFANA_URL + token) sourced from its secret.
    grafanaMcpWrapper = name: secretPath:
      pkgs.writeShellScript "grafana-mcp-wrapper-${name}" ''
        set -euo pipefail
        export $(grep -v '^#' ${secretPath} | xargs)
        exec ${pkgs.mcp-grafana}/bin/mcp-grafana "$@"
      '';

    # GrowthBook env (GB_API_KEY + GB_EMAIL, plus GB_API_URL/GB_APP_ORIGIN if self-hosted) sourced from its secret.
    growthbookMcpWrapper = secretPath:
      pkgs.writeShellScript "growthbook-mcp-wrapper" ''
        set -euo pipefail
        export $(grep -v '^#' ${secretPath} | xargs)
        exec ${pkgs.nodejs}/bin/npx -y @growthbook/mcp@latest "$@"
      '';
  in {
    config = lib.mkIf config.fireproof.dev.mcp.enable {
      age.secrets.grafana-mcp-env = {
        rekeyFile = ../../secrets/grafana-mcp-env.age;
        mode = "0600";
      };
      age.secrets.grafana-homelab-env = {
        rekeyFile = ../../secrets/grafana-homelab-env.age;
        mode = "0600";
      };
      age.secrets.growthbook-mcp-env = {
        rekeyFile = ../../secrets/growthbook-mcp-env.age;
        mode = "0600";
      };

      programs.mcp = {
        enable = true;
        servers = {
          linear.url = "https://mcp.linear.app/mcp";
          sentry.url = "https://mcp.sentry.dev/mcp";
          figma.url = "https://mcp.figma.com/mcp";
          insight.url = "https://insight.mcp.aortl.net/mcp";
          metabase.url = "https://metabase.aortl.net/api/metabase-mcp";
          snyk = {
            command = "${pkgs.nodejs}/bin/npx";
            args = ["-y" "snyk@latest" "mcp" "-t" "stdio"];
          };
          growthbook.command = toString (growthbookMcpWrapper config.age.secrets.growthbook-mcp-env.path);
          grafana-work.command = toString (grafanaMcpWrapper "work" config.age.secrets.grafana-mcp-env.path);
          grafana.command = toString (grafanaMcpWrapper "homelab" config.age.secrets.grafana-homelab-env.path);
        };
      };
    };
  };
}
