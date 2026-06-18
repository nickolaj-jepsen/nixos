{
  flake.modules.homeManager.vscode-agents = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.dev.enable) {
      xdg.configFile."Code/User/prompts/taskmaster.agent.md".source = ./taskmaster.agent.md;
    };
  };
}
