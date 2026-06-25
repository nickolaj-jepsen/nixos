{
  flake.modules.nixos.fish = {
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
    };
  };
  # nix-darwin only changes a user's login shell for users it "knows" (knownUsers),
  # and only when the configured uid matches — 501 is every Mac's first GUI user.
  # gid defaults to 20 (staff), matching macOS, and deletion is hard-guarded to
  # uid > 501, so the primary user can never be removed by a config change.
  flake.modules.darwin.fish = {
    config,
    pkgs,
    ...
  }: let
    inherit (config.fireproof) username;
  in {
    config = {
      programs.fish.enable = true;
      users.knownUsers = [username];
      users.users.${username} = {
        uid = 501;
        shell = pkgs.fish;
      };
    };
  };

  flake.modules.homeManager.fish = {pkgs, ...}: {
    config = {
      programs = {
        # Rich argument completions for kubectl/gh/docker/git/systemctl; composes
        # with the bespoke ds/worktree/wt completions (carapace defers to
        # existing fish completions).
        carapace = {
          enable = true;
          enableFishIntegration = true;
        };

        fish = {
          enable = true;
          shellInit = ''

            ${builtins.readFile ./theme.fish}
            ${builtins.readFile ./k8s.fish}
            ${builtins.readFile ./autocomplete.fish}
            ${builtins.readFile ./worktree.fish}
            ${builtins.readFile ./wt.fish}
            ${pkgs.nix-your-shell}/bin/nix-your-shell fish | source

          '';

          interactiveShellInit = ''
            # fzf.fish: reuse the delta diff highlighter and a bat file preview.
            # Leave Ctrl-R to fish's native history (--history= disables fzf.fish's
            # history binding); other pickers keep defaults (dir=Ctrl+Alt+F,
            # git_log=Ctrl+Alt+L, git_status=Ctrl+Alt+S).
            set -g fzf_diff_highlighter delta --paging=never
            set -g fzf_preview_file_cmd bat --color=always --style=numbers
            set -g fzf_fd_opts --hidden --exclude=.git
            fzf_configure_bindings --history=
          '';

          plugins = [
            {
              name = "bobthefish";
              inherit (pkgs.fishPlugins.bobthefish) src;
            }
            {
              name = "fzf-fish";
              inherit (pkgs.fishPlugins.fzf-fish) src;
            }
          ];
        };
      };
    };
  };
}
