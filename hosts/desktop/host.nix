{
  shared = {
    fireproof.hostname = "desktop";
    fireproof.hardware.gpuPciId = "10de:2c05";

    fireproof.desktop.enable = true;
    fireproof.desktop.bambu-studio.enable = true;
    fireproof.desktop.snapcast.enable = true;
    fireproof.dev.enable = true;
    fireproof.work.enable = true;
    fireproof.hardware.nvidia.enable = true;
    fireproof.claude-code.work.enable = true;
    fireproof.networkd.enable = true;
  };

  homeManager = {
    pkgs,
    lib,
    ...
  }: {
    home.packages = [pkgs.unstable.runelite];

    programs.ssh.settings."bastion.ao" = {
      ProxyJump = lib.mkForce null;
    };
  };
}
