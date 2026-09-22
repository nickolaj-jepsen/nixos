{
  flake.modules.homeManager.vscode-agents = {
    config,
    lib,
    pkgs,
    ...
  }: let
    # Same user dir HM's vscode module resolves; macOS VS Code never reads ~/.config/Code.
    prompts =
      if pkgs.stdenv.isDarwin
      then "Library/Application Support/Code/User/prompts"
      else "${config.xdg.configHome}/Code/User/prompts";
  in {
    config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.dev.enable) {
      home.file = {
        "${prompts}/taskmaster.agent.md".source = ./taskmaster.agent.md;

        "${prompts}/global.toolsets.jsonc".text = builtins.toJSON {
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
  };
}
