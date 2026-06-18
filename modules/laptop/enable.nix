# Carries the load-bearing fireproof.hardware.laptop fact for laptop hosts; it
# drives the battery/wifi/dimmableBacklight option defaults (read by the dms bar +
# control-center). The folder stamps aspectTags.laptop-enable = ["laptop"], so it is
# selected exactly when the laptop aspect is.
let
  m = {fireproof.hardware.laptop = true;};
in {
  flake.modules.nixos.laptop-enable = m;
  flake.modules.homeManager.laptop-enable = m;
}
