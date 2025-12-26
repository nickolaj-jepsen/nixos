{
  config = {
    fireproof = {
      desktop.enable = true;
      work.enable = true;
      dev.enable = true;
      hostname = "laptop";
      username = "nickolaj";
      hardware.battery = true;
    };
    facter.reportPath = ./facter.json;
  };

  imports = [
    ./configuration.nix
    ./disk-configuration.nix
    ./monitors.nix
    ./ssh.nix
  ];
}
