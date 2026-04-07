{inputs, ...}: {
  perSystem = {system, ...}: let
    pkgsUnstable = import inputs.nixpkgs-unstable {
      inherit system;
      config.allowUnfree = true;
    };
  in {
    overlayAttrs = {
      github-copilot-cli = pkgsUnstable.github-copilot-cli.overrideAttrs (_oldAttrs: rec {
        version = "1.0.19";
        src = pkgsUnstable.fetchurl {
          url = "https://registry.npmjs.org/@github/copilot/-/copilot-${version}.tgz";
          sha256 = "4a10063d43ed09747d6462e2240e603bd2c22419f015dc9fc0496564613ca9d1";
        };
        sourceRoot = "package";
        nativeBuildInputs = [pkgsUnstable.makeBinaryWrapper];
        buildInputs = [];
        installPhase = ''
          runHook preInstall

          install -d $out/lib/copilot $out/bin
          cp -r . $out/lib/copilot

          runHook postInstall
        '';
        postInstall = ''
          # Filename must explicitly be "copilot" for internal self-referencing
          makeWrapper ${pkgsUnstable.nodejs_24}/bin/node $out/bin/copilot \
            --add-flags "$out/lib/copilot/npm-loader.js --no-auto-update"
        '';
      });
    };
  };
}
