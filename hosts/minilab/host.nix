# minilab's host card. The snapcast aspect + its turntable capture live in the
# co-located snapcast.nix; oxcb-media is a bare aspect (module defaults suffice).
# Other NixOS-only settings live in sibling cards (system.nix, …).
{
  aspects = ["gui-dev" "physical" "oxcb-media"];

  shared = {
    fireproof.hostname = "minilab";
    fireproof.username = "nickolaj";
  };
}
