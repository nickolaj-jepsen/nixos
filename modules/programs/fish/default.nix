{
  username,
  pkgs,
  ...
}: {
  config = {
    programs.fish.enable = true;
    users.users.${username}.shell = pkgs.fish;

    # Fish enables generateCaches by default, which causes slow builds
    documentation.man.generateCaches = false;

    fireproof.home-manager.programs.fish = {
      enable = true;
      shellInit = ''

        ${builtins.readFile ./theme.fish}
        ${builtins.readFile ./k8s.fish}
        ${builtins.readFile ./autocomplete.fish}

      '';
      plugins = [
        {
          name = "to-fish";
          src = pkgs.fetchFromGitHub {
            owner = "joehillen";
            repo = "to-fish";
            rev = "52b151cfe67c00cb64d80ccc6dae398f20364938";
            sha256 = "sha256-DfDsU/qY2XdYlkLISIOv02ggHfKEpb+YompNWWjs5/A=";
          };
        }
        {
          name = "theme-bobthefish";
          src = pkgs.fetchFromGitHub {
            owner = "oh-my-fish";
            repo = "theme-bobthefish";
            rev = "e3b4d4eafc23516e35f162686f08a42edf844e40";
            hash = "sha256-cXOYvdn74H4rkMWSC7G6bT4wa9d3/3vRnKed2ixRnuA=";
          };
        }
      ];
    };
  };
}
