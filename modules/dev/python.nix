{
  flake.modules.homeManager.python = {
    lib,
    pkgs,
    ...
  }: let
    # Sets LD_LIBRARY_PATH for various python-based tools
    # Some python packages requires shared libraries to build C extensions.
    mkWrapLDLibraryPath = pkg: let
      mainProgram = pkg.meta.mainProgram or pkg.pname or (lib.getName pkg);
    in
      pkgs.symlinkJoin {
        name = "${pkg.name}-wrapped";
        paths = [pkg];
        nativeBuildInputs = [pkgs.makeWrapper];
        postBuild = ''
          wrapProgram $out/bin/${mainProgram} \
            --run "export LD_LIBRARY_PATH=\$NIX_LD_LIBRARY_PATH"
        '';
      };
  in {
    config = {
      home.packages = [
        (mkWrapLDLibraryPath pkgs.unstable.uv)
        (mkWrapLDLibraryPath pkgs.unstable.rye)
        (mkWrapLDLibraryPath pkgs.python3)
        (mkWrapLDLibraryPath pkgs.unstable.prek)
      ];

      # uv tool adds executable to $HOME/.local/bin, so add it to PATH
      home.sessionPath = [
        "$HOME/.local/bin"
      ];
    };
  };
}
