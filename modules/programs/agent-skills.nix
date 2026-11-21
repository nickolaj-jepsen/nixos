# Wires nickolaj-jepsen/agents into home-manager: its skills (`lib.skills`) go into the
# fireproof.agents.skills registry, and `fireproof.agents.devCheckout` says where its checkout is.
# Third-party skills are registered by their feature leaves instead (e.g. gh-stack in git.nix).
{inputs, ...}: {
  flake.modules.homeManager.agent-skills = {
    config,
    lib,
    ...
  }: {
    options.fireproof.agents.devCheckout = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/dev/agents";
      description = "Where nickolaj-jepsen/agents is checked out. `claude-dev` and `pi-dev` load the plugins from it in place of the store copies.";
    };

    # plain is personal (Nickolaj's writing style), so it lives here, not in the public agents repo.
    # The ponytail pair are copies pinned by hand: `metadata.source` in each names the upstream commit.
    config.fireproof.agents.skills =
      inputs.agents.lib.skills
      // lib.genAttrs ["plain" "ponytail-review" "ponytail-audit"] (name: ./agent-skills + "/${name}");
  };
}
