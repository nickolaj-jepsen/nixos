# Registers the agent-tools/skills/ directories (own skills; see agent-tools/README.md)
# into the fireproof.agents.skills registry. Third-party skills are registered
# by their feature leaves instead (e.g. gh-stack in git.nix).
{
  flake.modules.homeManager.agent-skills = {lib, ...}: {
    fireproof.agents.skills =
      lib.mapAttrs (name: _: ../../agent-tools/skills + "/${name}")
      (lib.filterAttrs (_: type: type == "directory") (builtins.readDir ../../agent-tools/skills));
  };
}
