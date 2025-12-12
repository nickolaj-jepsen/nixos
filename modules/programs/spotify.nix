# Enabled when: desktop
{
  config,
  lib,
  username,
  pkgs,
  ...
}: {
  config = lib.mkIf config.fireproof.desktop.enable {
    environment.systemPackages = with pkgs; [
      spotify
    ];

    age.secrets.spotify-player = {
      rekeyFile = ../../secrets/spotify-player.age;
      path = "/home/${username}/.cache/spotify-player/credentials.json";
      mode = "0600";
      owner = username;
    };

    fireproof.home-manager = {
      programs.spotify-player = {
        enable = true;
      };
    };
  };
}
