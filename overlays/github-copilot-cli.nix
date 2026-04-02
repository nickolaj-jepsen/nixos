{inputs, ...}: {
  perSystem = {system, ...}: let
    pkgsUnstable = import inputs.nixpkgs-unstable {
      inherit system;
      config.allowUnfree = true;
    };
  in {
    overlayAttrs = {
      github-copilot-cli = pkgsUnstable.github-copilot-cli.overrideAttrs (_oldAttrs: rec {
        version = "1.0.15";
        src = pkgsUnstable.fetchurl {
          url = "https://registry.npmjs.org/@github/copilot/-/copilot-${version}.tgz";
          sha256 = "72112e23d42165f5846e22010343c3e0581d5cb7be2dcde4c23597fbce76b3d1";
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
