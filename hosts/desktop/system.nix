# desktop's NixOS-only settings (auto-collected card).
{
  nixos = {
    programs.steam.enable = true;
    facter.reportPath = ./facter.json;
  };
}
