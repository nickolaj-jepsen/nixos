{
  flake.modules.homeManager.dms-agent-hub = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf (config.fireproof.dev.agent-hub.enable && pkgs.stdenv.isLinux) {
      programs.dank-material-shell.plugins.agentHub.src = ./plugin;
    };
  };
}
