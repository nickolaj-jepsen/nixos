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
      description = "Where nickolaj-jepsen/agents is checked out.";
    };

    config.fireproof.agents.skills = inputs.agents.lib.skills;
  };
}
