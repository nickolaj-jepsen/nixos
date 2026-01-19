{
  config,
  lib,
  inputs,
  ...
}: {
  config = lib.mkIf config.fireproof.desktop.enable {
    fireproof.home-manager = {
      imports = [
        inputs.dms-plugin-registry.modules.default
      ];
      programs.dank-material-shell.plugins = {
        emojiLauncher = {
          enable = true;
          settings = {
            enabled = true;
          };
        };
      };
    };
  };
}
