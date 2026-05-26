{
  config,
  lib,
  ...
}: {
  config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.dev.enable) {
    fireproof.home-manager = {
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
