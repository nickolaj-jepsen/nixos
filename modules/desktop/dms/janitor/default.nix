{
  flake.modules.homeManager.dms-janitor = {
    config,
    lib,
    pkgs,
    ...
  }: let
    plugin = pkgs.runCommand "dms-janitor-plugin" {} ''
      cp -r ${./plugin} $out
      chmod -R u+w $out
    '';
  in {
    # The pill replaces the storage widget in the bar and carries the checklist:
    # docs/janitor.md.
    config = lib.mkIf (config.fireproof.desktop.enable && pkgs.stdenv.isLinux && config.fireproof.janitor.enable) {
      programs.dank-material-shell.plugins.janitor = {
        src = plugin;
        settings = {
          # Store path, so the widget does not depend on the DMS service's PATH.
          command = lib.getExe pkgs.janitor;
        };
      };
    };
  };
}
