{
  config,
  pkgs,
  lib,
  ...
}: {
  config = {
    programs.fish.enable = true;
    users.users.${config.user.username}.shell = pkgs.fish;
    user.home-manager.programs.fish = {
      plugins = [
        {
          name = "to-fish";
          src = pkgs.fetchFromGitHub {
            owner = "joehillen";
            repo = "to-fish";
            rev = "52b151cfe67c00cb64d80ccc6dae398f20364938";
            sha256 = lib.fakeSha256;
          };
        }
        {
          name = "theme-bobthefish";
          src = pkgs.fetchFromGitHub {
            owner = "oh-my-fish";
            repo = "theme-bobthefish";
            rev = "e3b4d4eafc23516e35f162686f08a42edf844e40";
            sha256 = lib.fakeSha256;
          };
        }
      ];
    };
  };
}
