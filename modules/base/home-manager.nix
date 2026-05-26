{
  lib,
  config,
  options,
  ...
}: let
  inherit (config.fireproof) username;
  stateVersion = "24.11";
in {
  options.fireproof = {
    home-manager = lib.mkOption {
      type = options.home-manager.users.type.nestedTypes.elemType;
    };
  };
  config = {
    home-manager = {
      useUserPackages = true;
      useGlobalPkgs = true;
      users.${username} = lib.mkAliasDefinitions options.fireproof.home-manager;
    };

    # set the same version of home-manager as the system
    system.stateVersion = lib.mkDefault stateVersion;
    fireproof.home-manager.home.stateVersion = stateVersion;
  };
}
