# App configs Nix generates but the app may write to. Activation (every switch,
# and every login where home-manager runs as a user service) puts Nix's version
# back; `config-reset` does the same at will. What the app changed in between is
# kept as a diff under $XDG_STATE_HOME/config-reset, to port back into Nix.
{
  flake.modules.homeManager.writable-configs = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.fireproof.writableConfigs;
    manifest = pkgs.writeText "writable-configs.json" (builtins.toJSON (lib.mapAttrsToList (name: c: {
        inherit name;
        path = "${config.home.homeDirectory}/${config.home.file.${c.file}.target}";
        source = "${config.home.file.${c.file}.source}";
      })
      cfg));
    config-reset = pkgs.writeShellApplication {
      name = "config-reset";
      runtimeInputs = with pkgs; [coreutils diffutils findutils jq];
      runtimeEnv = {
        MANIFEST = manifest;
        STATE = "${config.xdg.stateHome}/config-reset";
      };
      text = builtins.readFile ./config-reset.bash;
    };
  in {
    options.fireproof.writableConfigs = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options.file = lib.mkOption {
          type = lib.types.str;
          example = lib.literalExpression ''"''${config.xdg.configHome}/zed/settings.json"'';
          description = ''
            The `home.file` entry to take over, by its attribute name (an
            `xdg.configFile` entry is `"''${config.xdg.configHome}/<name>"`). It is
            installed as a plain file instead of a store symlink.
          '';
        };
      });
      default = {};
      description = "Generated configs the app may write to, reset to Nix's version on activation; the attribute name names its history.";
    };

    config = lib.mkIf (cfg != {}) {
      home.file = lib.mapAttrs' (_: c: lib.nameValuePair c.file {enable = lib.mkForce false;}) cfg;
      home.packages = [config-reset];
      # After linkGeneration, which removes the store symlink a previous generation left there.
      home.activation.configReset = lib.hm.dag.entryAfter ["linkGeneration"] ''
        run ${lib.getExe config-reset}
      '';
    };
  };
}
