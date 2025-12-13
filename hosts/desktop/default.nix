{
  config = {
    fireproof = {
      hostname = "desktop";
      username = "nickolaj";
      desktop.enable = true;
      work.enable = true;
      dev.enable = true;
    };

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
