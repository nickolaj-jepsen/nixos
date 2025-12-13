{
  config = {
    fireproof = {
      hostname = "work";
      username = "nickolaj";
      desktop.enable = true;
      work.enable = true;
      dev.enable = true;
    };
    facter.reportPath = ./facter.json;
  };

  imports = [
    ./bluetooth.nix
    ./disk-configuration.nix
    ./monitors.nix
    ./networking.nix
    ./nvidia.nix
    ./ssh.nix
  ];
}
