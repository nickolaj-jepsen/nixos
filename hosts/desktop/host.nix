{
  shared = {
    fireproof.hostname = "desktop";
    fireproof.hardware.gpuPciId = "10de:2c05";

    fireproof.desktop.enable = true;
    fireproof.desktop.bambu-studio.enable = true;
    fireproof.desktop.snapcast.enable = true;
    fireproof.dev.enable = true;
    fireproof.dev.clickhouse.enable = false; # query ao's ClickHouse over SSH; no local client needed on desktop
    fireproof.work.enable = true;
    fireproof.hardware.nvidia.enable = true;
    fireproof.claude-code.work.enable = true;
    fireproof.networkd.enable = true;
  };

  homeManager = {lib, ...}: {
    programs.ssh.settings."bastion.ao" = {
      ProxyJump = lib.mkForce null;
    };
  };
}
