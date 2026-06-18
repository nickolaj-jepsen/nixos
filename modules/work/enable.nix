# Carries the load-bearing fireproof.work.enable fact for hosts in the work aspect
# (read by the always-on secrets/ssh.nix for work secret/host bits). The folder
# stamps aspectTags.work-enable = ["work"], so it is selected exactly when the work
# aspect is.
let
  m = {fireproof.work.enable = true;};
in {
  flake.modules.nixos.work-enable = m;
  flake.modules.homeManager.work-enable = m;
}
