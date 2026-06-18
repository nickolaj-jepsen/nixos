{
  aspects = ["workstation" "physical" "nvidia" "chromium" "bambu" "intellij" "clickhouse" "claude-work" "snapcast" "networkd"];

  shared = {
    fireproof.hostname = "desktop";
    fireproof.username = "nickolaj";
    fireproof.hardware.gpuPciId = "10de:2c05";
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
