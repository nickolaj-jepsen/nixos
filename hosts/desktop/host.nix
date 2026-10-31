{
  shared = {
    fireproof.hostname = "desktop";

    fireproof.desktop.enable = true;
    # Passphrase-only LUKS (no TPM slot), so the boot prompt already needs a human.
    fireproof.desktop.autologin.enable = true;
    fireproof.desktop.bambu-studio.enable = true;
    fireproof.desktop.jellyfin-media-player.enable = true;
    fireproof.desktop.ivpn.enable = true;
    fireproof.desktop.mullvad.enable = true;
    fireproof.desktop.snapcast.enable = true;
    fireproof.desktop.windows-vm = {
      enable = true;
      disk = "/dev/disk/by-id/nvme-Samsung_SSD_970_EVO_Plus_1TB_S6P7NF0T427535Z";
      # C: and its recovery partition; the Linux partitions on this disk stay out of the guest.
      partitions = ["7173f003-e6b7-11ed-a13b-e0d55ee69f82" "3cbf4de1-6e27-429d-95af-8c655599404c"];
      esp = "811a3c22-daaf-47d8-9b19-94adf986df12";
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
