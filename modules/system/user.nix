{
  flake.modules.nixos.user = {
    config,
    lib,
    ...
  }: let
    inherit (config.fireproof) username;
    inherit (config.age) secrets;
  in {
    age.secrets.hashed-user-password.rekeyFile = ../../secrets/hashed-user-password.age;

    users.users.${username} = {
      isNormalUser = true;
      extraGroups = ["wheel"];
      hashedPasswordFile = lib.mkDefault secrets.hashed-user-password.path;
    };
  };
}
