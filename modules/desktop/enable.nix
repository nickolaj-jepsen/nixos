# Carries the load-bearing fireproof.desktop.enable fact. Read in both evals —
# greetd (nixos) and scripts/ + dms control-center (home-manager) — so it is
# dual-declared.
let
  m = {fireproof.desktop.enable = true;};
in {
  flake.modules.nixos.desktop-enable = m;
  flake.modules.homeManager.desktop-enable = m;
}
