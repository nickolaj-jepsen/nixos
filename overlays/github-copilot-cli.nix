{inputs, ...}: {
  perSystem = {system, ...}: let
    pkgsUnstable = import inputs.nixpkgs-unstable {
      inherit system;
      config.allowUnfree = true;
    };
  in {
    overlayAttrs = {
      github-copilot-cli = pkgsUnstable.github-copilot-cli.overrideAttrs (_oldAttrs: rec {
        version = "1.0.5";
        src = pkgsUnstable.fetchurl {
          url = "https://registry.npmjs.org/@github/copilot/-/copilot-${version}.tgz";
          sha256 = "1d5f6cd6ac25d65f25b99643c1d29506d60549d730aaed38c371063218cb4816";
        };
        sourceRoot = "package";
        nativeBuildInputs = [pkgsUnstable.makeBinaryWrapper];
        buildInputs = [];
        installPhase = ''
          runHook preInstall

          install -d $out/libexec/copilot $out/bin
          cp -r . $out/libexec/copilot
          makeWrapper ${pkgsUnstable.nodejs_24}/bin/node $out/bin/copilot \
            --add-flags "$out/libexec/copilot/npm-loader.js --no-auto-update"

          runHook postInstall
        '';
      });
    };
  };
}
