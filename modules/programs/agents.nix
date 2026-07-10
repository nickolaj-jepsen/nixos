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
        context = config.programs.claude-code.context;
        # Shared with claude-code and pi; copilot only reads <name>/SKILL.md, so
        # the repo README would sit in the skills dir as a non-skill.
        skills = builtins.path {
          name = "copilot-skills";
          path = ../../skills;
          filter = path: _type: baseNameOf path != "README.md";
        };
      };
    };
  };
}
