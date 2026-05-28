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

    # Fish enables man cache generation by default, which causes slow builds
    documentation.man.cache.enable = false;

    fireproof.home-manager.programs.fish = {
      enable = true;
      shellInit = ''

        ${builtins.readFile ./theme.fish}
        ${builtins.readFile ./k8s.fish}
        ${builtins.readFile ./autocomplete.fish}
        ${builtins.readFile ./worktree.fish}
        ${builtins.readFile ./claude-wt.fish}
        ${pkgs.nix-your-shell}/bin/nix-your-shell fish | source

      '';
      plugins = [
        {
          name = "bobthefish";
          inherit (pkgs.fishPlugins.bobthefish) src;
        }
      ];
    };
  };
}
