{
  nixos = {
    programs.steam.enable = true;
    facter.reportPath = ./facter.json;

    users.users.nickolaj.extraGroups = ["dialout"]; # SO-101 arm's USB serial adapter (rustyarm)
  };
}
