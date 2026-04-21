{inputs, ...}: {
  perSystem = {system, ...}: let
    pkgsUnstable = import inputs.nixpkgs-unstable {
      inherit system;
      config.allowUnfree = true;
    };
  in {
    overlayAttrs = {
      github-copilot-cli = pkgsUnstable.github-copilot-cli.overrideAttrs (_oldAttrs: rec {
        version = "1.0.34";
        src = pkgsUnstable.fetchurl {
          url = "https://registry.npmjs.org/@github/copilot/-/copilot-${version}.tgz";
          sha256 = "415ce29412e3fabfa3999ceffb2ce968c5e07451b1b6d8ecd74e0d90905d7b47";
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
