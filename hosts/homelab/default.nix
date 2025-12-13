{
  config = {
    fireproof = {
      hostname = "homelab";
      username = "nickolaj";
      dev.enable = true;
      homelab.enable = true;
    };
    facter.reportPath = ./facter.json;
  };

  imports = [
    ./configuration.nix
    ./disks.nix
    ./networking.nix
  ];
}
