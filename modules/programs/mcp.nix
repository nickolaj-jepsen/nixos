{
  config,
  lib,
  pkgs,
  ...
}: {
  config = lib.mkIf config.fireproof.dev.enable {
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
      };
    };
  };
}
