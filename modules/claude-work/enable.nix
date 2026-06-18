# Carries the load-bearing fireproof.claude-code.work.enable fact for hosts in the
# claude-work aspect. Read by the always-on cli/claude-code leaf to install the
# claude-work wrapper package + ~/.claude-work/* symlinks (home-manager), so it is
# dual-declared. The folder stamps aspectTags.claude-work-enable = ["claude-work"],
# so it is selected exactly when the claude-work aspect is.
let
  m = {fireproof.claude-code.work.enable = true;};
in {
  flake.modules.nixos.claude-work-enable = m;
  flake.modules.homeManager.claude-work-enable = m;
}
