{
  config,
  lib,
  options,
  ...
}:
with lib; let
  cfg = config.user;
in {
  options.user = {
    username = mkOption {
      type = types.str;
      description = "The username of the user";
    };
    home-manager = mkOption {
      type = options.home-manager.users.type.functor.wrapped;
    };
  };

  config = {
    users.users.${cfg.username} = {
      isNormalUser = true;
      extraGroups = ["wheel"];
      initialPassword = "a";
    };

    home-manager = {
      useUserPackages = true;
      useGlobalPkgs = true;
    };
    home-manager.users.${cfg.username} = mkAliasDefinitions options.user.home-manager;
    user.home-manager.home.stateVersion = config.system.stateVersion;
  };
}
