# Carries the load-bearing fireproof.work.enable fact, read home-manager-side by
# secrets/ssh.nix for work secret/host bits (no nixos reader, so HM-only).
{
  flake.modules.homeManager.work-enable = {fireproof.work.enable = true;};
}
