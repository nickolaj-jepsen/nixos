# Spotify + spotify-player TUI. Home-manager half only: the credentials secret
# decrypts HM-side to spotify-player's fixed cache path (see secrets/hm-secrets.nix).
{
  flake.modules.homeManager.spotify = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.fireproof.desktop.enable {
      home.packages = [pkgs.spotify];

      age.secrets.spotify-player = {
        rekeyFile = ../../secrets/spotify-player.age;
        path = "${config.home.homeDirectory}/.cache/spotify-player/credentials.json";
        mode = "0600";
      };

      programs.spotify-player.enable = true;
    };
  };
}
