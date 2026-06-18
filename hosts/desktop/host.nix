# desktop's host card: the aspects it selects, its facts (shared into both evals),
# and its host-specific home-manager tweaks. NixOS-only settings live in the
# auto-collected default.nix sibling.
{
  aspects = ["workstation" "physical" "nvidia" "chromium" "bambu" "intellij" "clickhouse" "claude-work" "snapcast"];

  shared = {
    fireproof.hostname = "desktop";
    fireproof.username = "nickolaj";
    fireproof.hardware.gpuPciId = "10de:2c05";
    fireproof.monitors = import ./_monitors.nix;
  };

  homeManager = {
    pkgs,
    lib,
    ...
  }: {
    home.packages = [pkgs.unstable.runelite];

    programs.ssh.settings."bastion.ao" = {
      HostName = "62.199.221.53";
      ProxyJump = lib.mkForce null;
    };
  };
}
