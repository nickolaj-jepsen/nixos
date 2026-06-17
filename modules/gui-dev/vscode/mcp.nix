{
  flake.modules.homeManager.vscode-mcp = _: {
    config = {
      programs.vscode.profiles.default.enableMcpIntegration = true;

      xdg.configFile."Code/User/prompts/global.toolsets.jsonc".text = builtins.toJSON {
        issues = {
          tools = ["linear"];
          description = "A toolset for managing issues using Linear.";
          icon = "checklist";
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
