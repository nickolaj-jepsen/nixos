{pkgs, ...}: {
  config = {
    fireproof = {
      hostname = "desktop";
      username = "nickolaj";
      desktop.enable = true;
      desktop.bambu-studio.enable = true;
      work.enable = true;
      dev.enable = true;
    };
    programs.steam.enable = true;
    fireproof.home-manager.home.packages = [pkgs.unstable.runelite];

    facter.reportPath = ./facter.json;
  };

  imports = [
    ./boot.nix
    ./disk-configuration.nix
    ./monitors.nix
    ./networking.nix
    ./nvidia.nix
    ./ssh.nix
  ];
}
