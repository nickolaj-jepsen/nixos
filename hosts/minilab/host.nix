# minilab's host card. NixOS-only settings (snapcast turntable capture, oxcb
# macropad) live in the auto-collected default.nix sibling.
{
  aspects = ["gui-dev" "physical" "snapcast" "oxcb-media"];

  shared = {
    fireproof.hostname = "minilab";
    fireproof.username = "nickolaj";
    fireproof.monitors = import ./_monitors.nix;
  };
}
