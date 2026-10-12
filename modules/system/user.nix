{
  flake.modules.nixos.user = {config, ...}: let
    inherit (config.fireproof) username;
    inherit (config.age) secrets;
  in {
    age.secrets.hashed-user-password.rekeyFile = ../../secrets/hashed-user-password.age;

    # Users come only from config, so a rotated hashed-user-password reaches existing hosts (with mutable
    # users it only ever applied at creation). `passwd` changes don't survive the next activation.
    # agenix decrypts before the users step (its users.deps); if it can't, password login is locked
    # but SSH keys and passwordless sudo still work.
    users.mutableUsers = false;

    users.users.${username} = {
      isNormalUser = true;
      extraGroups = ["wheel"];
      hashedPasswordFile = secrets.hashed-user-password.path;
    };
  };
}
