# Spotify GUI + spotify-player TUI. On darwin the GUI is a Homebrew cask; the
# Linux desktop gets the nixpkgs GUI plus the spotify-player TUI (credentials secret
# decrypted HM-side to a fixed cache path — see secrets/hm-secrets.nix).
{
  flake.modules.darwin.spotify = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf config.fireproof.desktop.enable {
      homebrew.casks = ["spotify"];
    };
  };

  flake.modules.homeManager.spotify = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf (config.fireproof.desktop.enable && pkgs.stdenv.isLinux) {
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
