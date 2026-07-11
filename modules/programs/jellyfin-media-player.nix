# Jellyfin Media Player — Qt desktop client. Opt-in extra, Linux desktops only.
{
  flake.modules.homeManager.jellyfin-media-player = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.desktop.jellyfin-media-player.enable && pkgs.stdenv.isLinux) {
      home.packages = [
        pkgs.jellyfin-media-player
      ];
    };
  };
}
