{
  flake.modules.homeManager.phoenix-client = {
    config,
    lib,
    ...
  }: let
    client = import ./_phoenix-client.nix {inherit config;};
  in {
    config = lib.mkIf client.enabled {
      age.secrets.phoenix-client-key = {
        rekeyFile = client.secret;
        inherit (client) path;
        mode = "0600";
      };
    };
  };
}
