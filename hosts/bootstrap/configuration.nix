{username, ...}: {
  networking.wireless.enable = false;
  networking.networkmanager.enable = true;
  users.users.${username}.extraGroups = [ "networkmanager" ];
}
