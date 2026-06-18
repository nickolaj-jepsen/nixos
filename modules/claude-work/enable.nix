# Carries the load-bearing fireproof.claude-code.work.enable fact, read by the
# always-on cli/claude-code leaf (home-manager) to install the claude-work wrapper
# package + ~/.claude-work/* symlinks.
{
  flake.modules.homeManager.claude-work-enable = {fireproof.claude-code.work.enable = true;};
}
