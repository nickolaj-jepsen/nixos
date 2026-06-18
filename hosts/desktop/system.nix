{
  nixos = {
    programs.steam.enable = true;
    facter.reportPath = ./facter.json;
  };
}
