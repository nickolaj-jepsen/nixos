{
  flake.modules.homeManager.phoenix-client = {
    config,
    lib,
    ...
  }: let
    client = import ./_phoenix-client.nix {inherit config;};
  in {
    config = lib.mkIf client.enabled {
      # Shared by Claude Code and Pi tracing, independently of the Phoenix CLI.
      age.secrets.phoenix-client-key = {
        rekeyFile = client.secret;
        inherit (client) path;
        mode = "0600";
      };
    };
  };
}
