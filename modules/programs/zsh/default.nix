{
  config,
  pkgs,
  lib,
  ...
}: let
  inherit (config.fireproof) username;
in {
  config = {
    programs.zsh.enable = true;
    # Keep fish as default shell for now (as requested)
    # users.users.${username}.shell = pkgs.zsh;

    fireproof.home-manager.programs.zsh = {
      enable = true;
      enableCompletion = true;
      autocd = true;
      autosuggestion.enable = true;
      syntaxHighlighting.enable = true;
      zsh-abbr = {
        enable = true;
        abbreviations = import ./abbrs.nix {inherit lib;};
      };

      # History settings (similar to fish behavior)
      history = {
        size = 10000;
        save = 10000;
        ignoreDups = true;
        ignoreAllDups = true;
        ignoreSpace = true;
        share = true;
        extended = true;
      };

      initContent = ''
        # Source theme and configs
        ${builtins.readFile ./theme.zsh}
        ${builtins.readFile ./k8s.zsh}
        ${builtins.readFile ./autocomplete.zsh}

        # nix-your-shell for proper nix shell integration
        eval "$(${pkgs.nix-your-shell}/bin/nix-your-shell zsh)"

        # Completion settings (fish-like behavior)
        setopt COMPLETE_IN_WORD     # Complete from both ends of a word
        setopt ALWAYS_TO_END        # Move cursor to end after completion
        setopt MENU_COMPLETE        # Autoselect first completion entry

        # Enable colors in completion
        zstyle ':completion:*' list-colors ''${(s.:.)LS_COLORS}
        zstyle ':completion:*' menu select
        zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}' # Case insensitive

        # Key bindings for history search (fish-like)
        bindkey '^[[A' history-search-backward  # Up arrow
        bindkey '^[[B' history-search-forward   # Down arrow
        bindkey '^R' history-incremental-search-backward
      '';

      # Plugins
      plugins = [
        {
          name = "zsh-autopair";
          src = pkgs.fetchFromGitHub {
            owner = "hlissner";
            repo = "zsh-autopair";
            rev = "396c38a7468458ba29011f2ad4112e4fd35f78e6";
            sha256 = "sha256-PXHxPxFeoYXYMOC29YQKDdMnqTO0toyA7eJTSCV6PGE=";
          };
        }
      ];

      # Shell aliases (equivalent to fish abbreviations)
      shellAliases = {
        # General
        ls = "ls --color=auto";
        ll = "ls -la";
        la = "ls -a";
        ".." = "cd ..";
        "..." = "cd ../..";
        "~" = "cd ~";
      };
    };

    # Starship prompt
    fireproof.home-manager.programs.starship = {
      enable = true;
      enableZshIntegration = true;
      enableFishIntegration = false;
      settings = builtins.fromTOML (builtins.readFile ./starship.toml);
    };

    # Install additional packages for zsh
    environment.systemPackages = with pkgs; [
      fzf # For better history search
    ];
  };
}
