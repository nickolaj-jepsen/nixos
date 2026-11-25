# Wires nickolaj-jepsen/agents into home-manager: its skills (`lib.skills`) go into the
# fireproof.agents.skills registry, and `fireproof.agents.devCheckout` says where its checkout is.
# Third-party skills are registered by their feature leaves instead (e.g. gh-stack in git.nix).
{inputs, ...}: {
  flake.modules.homeManager.agent-skills = {
    config,
    lib,
    ...
  }: let
    cfg = config.fireproof.agents;
  in {
    options.fireproof.agents = {
      devCheckout = lib.mkOption {
        type = lib.types.str;
        default = "${config.home.homeDirectory}/dev/agents";
        description = "Where nickolaj-jepsen/agents is checked out.";
      };

      live = lib.mkEnableOption ''
        loading agents' skills and plugins from devCheckout instead of the pinned input: a
        skill edit applies at once, a plugin edit after `pnpm turbo run build` there. The
        names still come from the pinned input, so adding or removing one needs a switch'';

      # Claude Code and pi link these in place of the registry's store copies. The registry
      # itself stays store paths: home-manager's skill options copy what they're given.
      liveSkills = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        readOnly = true;
        internal = true;
        default = lib.optionalAttrs cfg.live (lib.mapAttrs (name: _: "${cfg.devCheckout}/skills/${name}") inputs.agents.lib.skills);
      };
    };

    config.fireproof.agents.skills = inputs.agents.lib.skills;
  };
}
