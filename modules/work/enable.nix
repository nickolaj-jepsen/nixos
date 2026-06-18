# Carries the load-bearing fireproof.work.enable fact, read by the always-on
# secrets/ssh.nix for work secret/host bits.
let
  m = {fireproof.work.enable = true;};
in {
  flake.modules.nixos.work-enable = m;
  flake.modules.homeManager.work-enable = m;
}
