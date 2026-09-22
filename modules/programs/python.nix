{
  flake.modules.homeManager.python = {
    config,
    lib,
    pkgs,
    ...
  }: let
    # pip-installed manylinux wheels need nix-ld's libraries. Appended so a
    # devShell's LD_LIBRARY_PATH wins; a no-op where nix-ld isn't set up.
    python3 =
      if pkgs.stdenv.isLinux
      then
        pkgs.symlinkJoin {
          name = "${pkgs.python3.name}-wrapped";
          paths = [pkgs.python3];
          nativeBuildInputs = [pkgs.makeWrapper];
          postBuild = ''
            wrapProgram $out/bin/python3 \
              --run '[ -z "$NIX_LD_LIBRARY_PATH" ] || export LD_LIBRARY_PATH="''${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}$NIX_LD_LIBRARY_PATH"'
          '';
        }
      else pkgs.python3;
  in {
    config = lib.mkIf config.fireproof.dev.enable {
      home.packages = [
        pkgs.unstable.uv
        pkgs.unstable.prek
        python3
        # Drop-in for tools and hook scripts that invoke `pre-commit` by name
        (pkgs.writeShellScriptBin "pre-commit" ''exec prek "$@"'')
      ];

      # Venvs made from the Nix python bypass its wrapper; uv's own CPython runs
      # through nix-ld instead.
      home.sessionVariables.UV_PYTHON_PREFERENCE = "only-managed";

      # uv tool adds executable to $HOME/.local/bin, so add it to PATH
      home.sessionPath = [
        "$HOME/.local/bin"
      ];
    };
  };
}
