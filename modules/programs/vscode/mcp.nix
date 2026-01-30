{
  config,
  lib,
  ...
}: {
  config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.dev.enable) {
    fireproof.home-manager = {
      programs.vscode.profiles.default.userMcp = {
        inputs = [
          {
            type = "promptString";
            id = "context7-api-key";
            description = "Context7 API Key";
            password = true;
          }
          {
            type = "promptString";
            id = "growthbook-api-key";
            description = "GrowthBook API Key";
            password = true;
          }
        ];
        servers = {
          linear = {
            url = "https://mcp.linear.app/mcp";
            type = "http";
          };
          sentry = {
            url = "https://mcp.sentry.dev/mcp";
            type = "http";
          };
          figma = {
            url = "https://mcp.figma.com/mcp";
            type = "http";
          };
          context7 = {
            type = "http";
            url = "https://mcp.context7.com/mcp";
            headers = {
              CONTEXT7_API_KEY = "\${input:context7-api-key}";
            };
          };
          insight = {
            url = "https://insight.mcp.aortl.net/mcp";
            type = "http";
          };
          growthbook = {
            type = "stdio";
            command = "npx";
            args = ["-y" "@growthbook/mcp@1.5.0"];
            env = {
              GB_API_KEY = "\${input:growthbook-api-key}";
              GB_EMAIL = "nij@ao.dk";
            };
          };
        };
      };
      
      xdg.configFile."Code/User/prompts/global.toolsets.jsonc".text = builtins.toJSON {
        issues = {
          tools = ["linear"];
          description = "A toolset for managing issues using Linear.";
          icon = "checklist";
        };
        growthbook = {
          tools = ["growthbook"];
          description = "A toolset for A/B testing and feature flagging using GrowthBook.";
          icon = "beaker";
        };
        sentry = {
          tools = ["sentry"];
          description = "A toolset for error tracking and performance monitoring using Sentry.";
          icon = "debug";
        };
      };
    };
  };
}
