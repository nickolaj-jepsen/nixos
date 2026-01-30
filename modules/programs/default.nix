_: {
  imports = [
    ./fish/default.nix
    ./claude.nix
    ./comma.nix
    ./core.nix
    ./git.nix
    ./jujutsu.nix
    ./just.nix
    ./neovim.nix
    ./zellij.nix
    ./zoxide.nix
    ./systemd-manager-tui.nix
    ./llm.nix

    # Apps (migrated from legacy_modules/apps)
    ./chromium.nix
    ./ferdium.nix
    ./firefox.nix
    ./ghostty.nix
    ./obsidian.nix
    ./pycharm.nix
    ./slack.nix
    ./spotify.nix
    ./sublime-merge.nix
    ./vscode
    ./zed.nix
    ./zen.nix

    # Dev tools (migrated from legacy_modules/dev)
    ./clickhouse.nix
    ./docker.nix
    ./javascript.nix
    ./k8s.nix
    ./nats.nix
    ./playwright.nix
    ./postgres.nix
    ./python.nix
    ./tilt.nix
    ./opencode.nix
  ];
}
