{
  flake.modules.homeManager.phoenix-client = {
    config,
    lib,
    pkgs,
    ...
  }: let
    client = import ./_phoenix-client.nix {inherit config;};
    px = lib.getExe pkgs.phoenix-cli;
    managedCli = pkgs.writeShellScriptBin "px" ''
      # Explicit connection settings use upstream resolution without the homelab key.
      if [ -n "''${PHOENIX_ENDPOINT:-}''${PHOENIX_HOST:-}''${PHOENIX_COLLECTOR_ENDPOINT:-}" ] ||
         [ -n "''${PHOENIX_API_KEY:-}''${PHOENIX_PROFILE:-}''${PHOENIX_CLIENT_HEADERS:-}" ]; then
        exec ${px} "$@"
      fi
      # Setup/auth can write credentials to files; leave those flows unmanaged.
      case "''${1:-}" in
        setup|setup-mcp|auth|profile|self) exec ${px} "$@" ;;
      esac
      for arg in "$@"; do
        case "$arg" in
          --endpoint|--endpoint=*|--api-key|--api-key=*|--profile|--profile=*) exec ${px} "$@" ;;
        esac
      done
      export PHOENIX_ENDPOINT=${lib.escapeShellArg client.baseUrl}
      if [ -r ${lib.escapeShellArg client.path} ]; then
        PHOENIX_API_KEY=$(<${lib.escapeShellArg client.path})
        export PHOENIX_API_KEY
      fi
      exec ${px} "$@"
    '';
  in {
    config = lib.mkIf client.enabled {
      home.packages = [
        (pkgs.symlinkJoin {
          name = "phoenix-cli-configured";
          paths = [managedCli pkgs.phoenix-cli];
          postBuild = ''
            ln -sfn px "$out/bin/phoenix-cli"
          '';
        })
      ];
      age.secrets.phoenix-client-key = {
        rekeyFile = client.secret;
        inherit (client) path;
        mode = "0600";
      };
    };
  };
}
