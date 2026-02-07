{
  config,
  pkgs,
  ...
}: let
  inherit (config.fireproof) username;
in {
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
        ${pkgs.nix-your-shell}/bin/nix-your-shell fish | source

      '';
      plugins = [
        pkgs.fishPlugins.to-fish
        pkgs.fishPlugins.theme-bobthefish
      ];
    };
  };
}
