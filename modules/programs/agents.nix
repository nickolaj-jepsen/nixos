{
  flake.modules.homeManager.agents = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.fireproof.dev.enable {
      programs.github-copilot-cli = {
        enable = true;
        package = pkgs.unstable.github-copilot-cli;
        # Pulls in programs.mcp.servers (see modules/programs/mcp.nix).
        enableMcpIntegration = true;
        # Shared with claude-code and pi; keep it agent-agnostic.
        context = builtins.readFile ./agent-context.md;
        # An attrset, not a linkFarm: the module's pathIsDirectory check on a path is IFD, which breaks the darwin eval in Linux CI.
        skills = config.fireproof.agents.skills;
      };
    };
  };
}
