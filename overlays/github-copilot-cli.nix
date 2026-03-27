{inputs, ...}: {
  perSystem = {system, ...}: let
    pkgsUnstable = import inputs.nixpkgs-unstable {
      inherit system;
      config.allowUnfree = true;
    };
  in {
    overlayAttrs = {
      github-copilot-cli = pkgsUnstable.github-copilot-cli.overrideAttrs (_oldAttrs: rec {
        version = "1.0.12";
        src = pkgsUnstable.fetchurl {
          url = "https://registry.npmjs.org/@github/copilot/-/copilot-${version}.tgz";
          sha256 = "431cc7fe7401e5dc463baba0a7b47a8f8dfd1935b9c5469f2a91b746670cd789";
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
