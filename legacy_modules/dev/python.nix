{
  pkgs,
  pkgsUnstable,
  ...
}: {
  environment.systemPackages = [
    pkgsUnstable.uv
    pkgsUnstable.rye
    pkgs.python3
  ];

  # uv tool adds executable to $HOME/.local/bin, so add it to PATH
  fireproof.home-manager = {
    home.sessionPath = [
      "$HOME/.local/bin"
    ];
  };
}
