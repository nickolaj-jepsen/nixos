{inputs, ...}: {
  perSystem = {system, ...}: let
    pkgsUnstable = import inputs.nixpkgs-unstable {
      inherit system;
      config.allowUnfree = true;
    };
  in {
    overlayAttrs = {
      github-copilot-cli = pkgsUnstable.github-copilot-cli.overrideAttrs (_oldAttrs: rec {
        version = "1.0.3";
        src = pkgsUnstable.fetchurl {
          url = "https://registry.npmjs.org/@github/copilot/-/copilot-${version}.tgz";
          sha256 = "049eff1b9de86ae74258e7225e8ceefe0d369c293c8065e8285cd69a9efc5e65";
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
