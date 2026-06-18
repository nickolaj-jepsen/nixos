# Carries the load-bearing fireproof.desktop.enable fact for hosts in the desktop
# aspect. Read in both evals: greetd (nixos) and scripts/ + dms control-center
# (home-manager), so it is dual-declared. The folder stamps aspectTags.desktop-enable
# = ["desktop"], so it is selected exactly when the desktop aspect is.
let
  m = {fireproof.desktop.enable = true;};
in {
  flake.modules.nixos.desktop-enable = m;
  flake.modules.homeManager.desktop-enable = m;
}
