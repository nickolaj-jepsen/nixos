{
  pkgs,
  pkgsUnstable,
  ...
}: {
  environment.systemPackages = [
    (pkgs.symlinkJoin {
      name = "uv";
      paths = [ pkgsUnstable.uv ];
      nativeBuildInputs = [ pkgs.makeWrapper ];
      postBuild = ''
        wrapProgram $out/bin/uv \
          --run "export LD_LIBRARY_PATH=\$NIX_LD_LIBRARY_PATH"
      '';
    })
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
