{
  username,
  stateVersion,
  ...
}: {
  imports = [
    ../../targets/graphical.nix
    ../../targets/shell.nix
  ];

  config = {
    user.username = username;
    system.stateVersion = stateVersion;
    monitor.primary.resolution = "1920x1080";
    services.qemuGuest.enable = true;
    services.spice-vdagentd.enable = true;
  };
}
