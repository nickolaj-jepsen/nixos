# Carries the load-bearing fireproof.claude-code.work.enable fact. Read by the
# always-on cli/claude-code leaf to install the claude-work wrapper package +
# ~/.claude-work/* symlinks (home-manager), so it is dual-declared.
let
  m = {fireproof.claude-code.work.enable = true;};
in {
  flake.modules.nixos.claude-work-enable = m;
  flake.modules.homeManager.claude-work-enable = m;
}
