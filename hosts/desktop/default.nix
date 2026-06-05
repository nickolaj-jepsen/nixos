{pkgs, ...}: {
  config = {
    fireproof = {
      hostname = "desktop";
      username = "nickolaj";
      desktop.enable = true;
      desktop.bambu-studio.enable = true;
      desktop.snapcast.enable = true;
      work.enable = true;
      dev.enable = true;
      claude-code.work.enable = true;
      hardware.nvidia.enable = true;
      # Discrete GPU PCI id (from `dgop gpu --json`), enables the DMS GPU widgets.
      hardware.gpuPciId = "10de:2c05";
    };
    programs.steam.enable = true;
    fireproof.home-manager.home.packages = [pkgs.unstable.runelite];

    facter.reportPath = ./facter.json;
  };
}
