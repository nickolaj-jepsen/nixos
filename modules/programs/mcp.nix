# MCP servers, incl. grafana wrappers that source their env from a secret.
# Home-manager half only: the secrets decrypt HM-side (see modules/base/hm-secrets.nix).
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
        set -a; . "${secretPath}"; set +a
        exec ${pkgs.mcp-grafana}/bin/mcp-grafana "$@"
      '';
  in {
    config = lib.mkIf config.fireproof.dev.mcp.enable (lib.mkMerge [
      {
        programs.mcp.enable = true;
      }
      (lib.mkIf config.fireproof.dev.mcp.homelab.enable {
        age.secrets.grafana-homelab-env = {
          rekeyFile = ../../secrets/grafana-homelab-env.age;
          mode = "0600";
        };

        programs.mcp.servers.grafana.command = toString (grafanaMcpWrapper "homelab" config.age.secrets.grafana-homelab-env.path);
      })
      # Work-owned servers go to the claude-work plugin instead of
      # programs.mcp.servers, which every agent reads. Also keeps the tokens off
      # hosts without the work profile.
      (lib.mkIf (config.fireproof.work.enable && config.fireproof.claude-code.work.enable) {
        age.secrets.grafana-mcp-env = {
          rekeyFile = ../../secrets/grafana-mcp-env.age;
          mode = "0600";
        };

        fireproof.claude-code.workMcpServers = {
          figma.url = "https://mcp.figma.com/mcp";
          linear.url = "https://mcp.linear.app/mcp";
          sentry.url = "https://mcp.sentry.dev/mcp";
          insight.url = "https://insight.mcp.aortl.net/mcp";
          metabase.url = "https://metabase.aortl.net/api/metabase-mcp";
          # Hosted GrowthBook MCP; auth is browser OAuth, so no API-key secret.
          growthbook.url = "https://mcp.growthbook.io/mcp";
          grafana-work.command = toString (grafanaMcpWrapper "work" config.age.secrets.grafana-mcp-env.path);
        };
      })
    ]);
  };
}
