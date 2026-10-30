{
  shared = {
    fireproof.hostname = "desktop";

    fireproof.desktop.enable = true;
    fireproof.desktop.bambu-studio.enable = true;
    fireproof.desktop.jellyfin-media-player.enable = true;
    fireproof.desktop.ivpn.enable = true;
    fireproof.desktop.mullvad.enable = true;
    fireproof.desktop.snapcast.enable = true;
    fireproof.desktop.windows-vm = {
      enable = true;
      disk = "/dev/disk/by-id/nvme-Samsung_SSD_970_EVO_Plus_1TB_S6P7NF0T427535Z";
      extraDisks = ["/dev/disk/by-id/ata-ST2000DM001-1CH164_Z1E26NPV"];
    };
    fireproof.dev.enable = true;
    fireproof.dev.clickhouse.enable = false; # query ao's ClickHouse over SSH; no local client needed on desktop
    fireproof.dev.llm.enable = true; # RTX 5070 Ti (16 GiB): relies on the vramGiB default
    fireproof.work.enable = true;
    fireproof.scripts.tunnel-home.enable = true;
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
