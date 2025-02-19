{
  lib,
  options,
  username,
  config,
  ...
}:
with lib; let
  inherit (config.age) secrets;
in {
  options.fireproof = {
    home-manager = lib.mkOption {
      type = options.home-manager.users.type.functor.wrapped;
    };
  };
  config = {
    age.secrets.hashed-user-password.rekeyFile = ../../../secrets/hashed-user-password.age;

    users.users.${username} = {
      isNormalUser = true;
      extraGroups = ["wheel"];
      initialPassword = "password";
      #hashedPasswordFile = secrets.hashed-user-password.path;
    };

    home-manager = {
      useUserPackages = true;
      useGlobalPkgs = true;
    };
    home-manager.users.${username} = mkAliasDefinitions options.fireproof.home-manager;

    # set the same version of home-manager as the system
    fireproof.home-manager.home.stateVersion = "24.11";
    system.stateVersion = "24.11";
  };
}
