{
  flake.modules.homeManager.vscode-agents = _: {
    config = {
      xdg.configFile."Code/User/prompts/taskmaster.agent.md".source = ./taskmaster.agent.md;
    };
  };
}
