# Carries the load-bearing fireproof.hardware.laptop fact; it drives the
# battery/wifi/dimmableBacklight option defaults (read by the dms bar +
# control-center).
let
  m = {fireproof.hardware.laptop = true;};
in {
  flake.modules.nixos.laptop-enable = m;
  flake.modules.homeManager.laptop-enable = m;
}
