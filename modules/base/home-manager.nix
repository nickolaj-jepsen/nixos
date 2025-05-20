{
  lib,
  options,
  username,
  ...
}:
with lib; {
  options.fireproof = {
    home-manager = lib.mkOption {
      type = options.home-manager.users.type.nestedTypes.elemType;
    };
  };
  config = {
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
