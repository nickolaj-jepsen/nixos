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
        # Stable node: unstable's would be a second ~130 MB nodejs + icu in the closure.
        package = pkgs.unstable.github-copilot-cli.override {inherit (pkgs) nodejs;};
        # Pulls in programs.mcp.servers (see modules/programs/mcp.nix).
        enableMcpIntegration = true;
        # Shared with claude-code and pi; keep it agent-agnostic.
        context = builtins.readFile ./agent-context.md;
        # An attrset, not a linkFarm: the module pathIsDirectory-checks a path, which on a derivation is IFD.
        skills = config.fireproof.agents.skills;
      };
    };
  };
}
