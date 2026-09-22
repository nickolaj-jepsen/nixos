{
  flake.modules.homeManager.vscode-mcp = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.dev.enable) {
      programs.vscode.profiles.default.enableMcpIntegration = true;
    };
  };
}
