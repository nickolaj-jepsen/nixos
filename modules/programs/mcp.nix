{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (config.fireproof) username;

  grafanaMcpWrapper = pkgs.writeShellScript "grafana-mcp-wrapper" ''
    set -euo pipefail
    export $(grep -v '^#' ${config.age.secrets.grafana-mcp-env.path} | xargs)
    exec ${pkgs.mcp-grafana}/bin/mcp-grafana "$@"
  '';
in {
  config = lib.mkIf config.fireproof.dev.enable {
    age.secrets.grafana-mcp-env = {
      rekeyFile = ../../secrets/grafana-mcp-env.age;
      mode = "0600";
      owner = username;
    };

    fireproof.home-manager.programs.mcp = {
      enable = true;
      servers = {
        linear.url = "https://mcp.linear.app/mcp";
        sentry.url = "https://mcp.sentry.dev/mcp";
        figma.url = "https://mcp.figma.com/mcp";
        insight.url = "https://insight.mcp.aortl.net/mcp";
        metabase.url = "https://metabase.aortl.net/api/mcp";
        snyk = {
          command = "${pkgs.nodejs}/bin/npx";
          args = ["-y" "snyk@latest" "mcp" "-t" "stdio"];
        };
        grafana.command = toString grafanaMcpWrapper;
      };
    };
  };
}
