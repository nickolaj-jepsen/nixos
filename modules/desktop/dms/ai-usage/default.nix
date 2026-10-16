{
  flake.modules.homeManager.dms-ai-usage = {
    config,
    lib,
    pkgs,
    ...
  }: let
    # Simple Icons (CC0), filled white so the widget's MultiEffect can tint them.
    simpleIcon = name: hash:
      pkgs.fetchurl {
        url = "https://cdn.jsdelivr.net/npm/simple-icons@16.33.0/icons/${name}.svg";
        inherit hash;
      };
    plugin = pkgs.runCommand "dms-ai-usage-plugin" {} ''
      cp -r ${./plugin} $out
      chmod -R u+w $out
      sed 's/<svg /<svg fill="#fff" /' ${simpleIcon "claude" "sha256-LW/aeesY3czKNbeZ7rPOzg36vCJSDOOxCr0lZo35+pM="} > $out/icons/claude.svg
      sed 's/<svg /<svg fill="#fff" /' ${simpleIcon "githubcopilot" "sha256-xyweABjoSzEoxaGsQ+wr4TWsbsTrnA6hjtdkFtI/KvM="} > $out/icons/copilot.svg
    '';
  in {
    config = lib.mkIf (config.fireproof.desktop.enable && pkgs.stdenv.isLinux && config.fireproof.dev.ai-usage.enable) {
      programs.dank-material-shell.plugins.aiUsage = {
        src = plugin;
        settings = {
          # Store path, so the widget doesn't depend on the DMS service's PATH.
          command = lib.getExe pkgs.ai-usage;
          # Provider ids from ai-usage's config; a host card overrides this to keep one off the bar.
          hiddenProviders = lib.mkDefault [];
        };
      };
    };
  };
}
