{inputs, ...}: {
  perSystem = {system, ...}: let
    pkgsUnstable = import inputs.nixpkgs-unstable {
      inherit system;
      config.allowUnfree = true;
    };
  in {
    overlayAttrs = {
      github-copilot-cli = pkgsUnstable.github-copilot-cli.overrideAttrs (_oldAttrs: rec {
        version = "1.0.21";
        src = pkgsUnstable.fetchurl {
          url = "https://registry.npmjs.org/@github/copilot/-/copilot-${version}.tgz";
          sha256 = "be1167c8b667a275bae740606e0edc2518684ce277519c3388e7ee0b91e1a227";
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
