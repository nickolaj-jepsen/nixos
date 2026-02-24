_: {
  perSystem = {pkgs, ...}: let
    version = "0.10.0";

    src = pkgs.fetchFromGitHub {
      owner = "subsy";
      repo = "ralph-tui";
      rev = "v${version}";
      hash = "sha256-hCB5FuZeVr3uMTDlcn2fVAk6WmmIjx5RbyWZNhJxxs0=";
    };

    bunDeps = pkgs.stdenv.mkDerivation {
      pname = "ralph-tui-deps";
      inherit version src;

      nativeBuildInputs = [pkgs.bun];

      dontFixup = true;
      dontConfigure = true;

      impureEnvVars = pkgs.lib.fetchers.proxyImpureEnvVars;

      buildPhase = ''
        export HOME=$(mktemp -d)
        bun install --frozen-lockfile
      '';

      installPhase = ''
        cp -r node_modules $out
      '';

      outputHashMode = "recursive";
      outputHashAlgo = "sha256";
      outputHash = "sha256-e4ISNTCmsV24kQFHDAtuEOK6o1CKxixSf1+ofGAUzOA=";
    };
  in {
    overlayAttrs = {
      ralph-tui = pkgs.stdenv.mkDerivation {
        pname = "ralph-tui";
        inherit version src;

        nativeBuildInputs = [pkgs.bun pkgs.makeWrapper];

        dontFixup = true;
        dontConfigure = true;

        buildPhase = ''
          export HOME=$(mktemp -d)
          cp -r ${bunDeps} node_modules
          chmod -R u+w node_modules
          bun build ./src/cli.tsx --compile --outfile ralph-tui
        '';

        installPhase = ''
          install -Dm755 ralph-tui $out/bin/ralph-tui
        '';

        meta = {
          description = "AI Agent Loop Orchestrator TUI";
          homepage = "https://github.com/subsy/ralph-tui";
        };
      };
    };
  };
}
