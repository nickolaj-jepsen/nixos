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
        package = pkgs.github-copilot-cli;
        # Pulls in programs.mcp.servers (see modules/programs/mcp.nix).
        enableMcpIntegration = true;
        # Shared with claude-code and pi; keep it agent-agnostic.
        context = builtins.readFile ./agent-context.md;
        # The fireproof.agents.skills registry, linked into one dir since this
        # option takes a single path.
        skills = "${pkgs.linkFarm "copilot-skills" config.fireproof.agents.skills}";
      };
    };
  };
}
