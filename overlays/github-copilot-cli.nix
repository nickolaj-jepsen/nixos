{inputs, ...}: {
  perSystem = {system, ...}: let
    pkgsUnstable = import inputs.nixpkgs-unstable {
      inherit system;
      config.allowUnfree = true;
    };
    # Since 1.0.27 upstream dropped the universal tarball nixpkgs builds from;
    # the release now ships one tgz per platform (same `package/` layout).
    plat =
      {
        x86_64-linux = {
          dir = "linux-x64";
          hash = "sha256-z70Rb+FZviiaut8sK/GKJairCe7KVKCR1AJeHLzaRwk=";
        };
        aarch64-linux = {
          dir = "linux-arm64";
          hash = "sha256-saIHbLOlh+uivG9HjONeU/IKNNDWm0GAdDmzMC3191o=";
        };
        x86_64-darwin = {
          dir = "darwin-x64";
          hash = "sha256-biISO2sXX+HWeGo+4vXRu3M9BN839sFBN0McAcPBWNI=";
        };
        aarch64-darwin = {
          dir = "darwin-arm64";
          hash = "sha256-Tr+isxFUmWQgQX3ivglJ7x9ONa8JQ9ZVFUdNWuPCKxE=";
        };
      }
      .${
        system
      } or (throw "github-copilot-cli overlay: unsupported system ${system}");
  in {
    overlayAttrs = {
      github-copilot-cli = pkgsUnstable.github-copilot-cli.overrideAttrs (finalAttrs: _: {
        version = "1.0.70";
        src = pkgsUnstable.fetchurl {
          url = "https://github.com/github/copilot-cli/releases/download/v${finalAttrs.version}/github-copilot-${finalAttrs.version}-${plat.dir}.tgz";
          inherit (plat) hash;
        };
      });
    };
  };
}
