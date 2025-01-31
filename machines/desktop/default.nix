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
  };
}
