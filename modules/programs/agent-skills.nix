# Registers the repo-root skills/ directories (own skills; see skills/README.md)
# into the fireproof.agents.skills registry. Third-party skills are registered
# by their feature leaves instead (e.g. gh-stack in git.nix).
{
  flake.modules.homeManager.agent-skills = {lib, ...}: {
    fireproof.agents.skills =
      lib.mapAttrs (name: _: ../../skills + "/${name}")
      (lib.filterAttrs (_: type: type == "directory") (builtins.readDir ../../skills));
  };
}
