{
  lib,
  config,
  options,
  ...
}:
with lib; let
  inherit (config.fireproof) username;
in {
  options.fireproof = {
    home-manager = lib.mkOption {
      type = options.home-manager.users.type.nestedTypes.elemType;
    };
  };
  config = rec {
    home-manager = {
      useUserPackages = true;
      useGlobalPkgs = true;
    };
    home-manager.users.${username} = mkAliasDefinitions options.fireproof.home-manager;

    # set the same version of home-manager as the system
    system.stateVersion = lib.mkDefault "24.11";
    fireproof.home-manager.home.stateVersion = system.stateVersion;
  };
}
