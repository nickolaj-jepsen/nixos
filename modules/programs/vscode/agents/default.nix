{
  config,
  lib,
  ...
}: {
  config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.dev.enable) {
    fireproof.home-manager.xdg.configFile."Code/User/prompts/taskmaster.agent.md".source = ./taskmaster.agent.md;
  };
}
