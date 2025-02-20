{
  username,
  pkgsUnstable,
  ...
}: {
  virtualisation.virtualbox.host.enable = true;
  virtualisation.virtualbox.host.package = pkgsUnstable.virtualbox;
  users.extraGroups.vboxusers.members = [username];
}
