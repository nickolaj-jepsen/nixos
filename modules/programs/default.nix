_: {
  imports = [
    ./fish/default.nix
    ./comma.nix
    ./core.nix
    ./git.nix
    ./just.nix
    ./neovim.nix
    ./zellij.nix
    ./zoxide.nix

    # Apps (migrated from legacy_modules/apps)
    ./bambu-studio.nix
    ./chromium.nix
    ./ferdium.nix
    ./firefox
    ./ghostty.nix
    ./obsidian.nix
    ./remmina.nix
    ./pycharm.nix
    ./slack.nix
    ./spotify.nix
    ./sublime-merge.nix
    ./vscode

    # Dev tools (migrated from legacy_modules/dev)
    ./clickhouse.nix
    ./docker.nix
    ./javascript.nix
    ./k8s.nix
    ./nats.nix
    ./postgres.nix
    ./python.nix
    ./tilt.nix
    ./agents.nix
    ./claude-code.nix
    ./emdash.nix
    ./fnug.nix
  ];
}
