{
  flake.modules.homeManager.dms-agent-hub = {
    config,
    lib,
    pkgs,
    ...
  }: let
    # Simple Icons (CC0), filled white so the widget's MultiEffect can tint it.
    claudeIcon = pkgs.fetchurl {
      url = "https://cdn.jsdelivr.net/npm/simple-icons@16.33.0/icons/claude.svg";
      hash = "sha256-LW/aeesY3czKNbeZ7rPOzg36vCJSDOOxCr0lZo35+pM=";
    };
    plugin = pkgs.runCommand "dms-agent-hub-plugin" {} ''
      cp -r ${./plugin} $out
      chmod -R u+w $out
      sed 's/<svg /<svg fill="#fff" /' ${claudeIcon} > $out/icons/claude.svg
    '';
  in {
    config = lib.mkIf (config.fireproof.dev.agent-hub.enable && pkgs.stdenv.isLinux) {
      programs.dank-material-shell.plugins.agentHub.src = plugin;
    };
  };
}
