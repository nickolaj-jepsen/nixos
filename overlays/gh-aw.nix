_: {
  perSystem = {
    pkgs,
    system,
    ...
  }: let
    platformMap = {
      "x86_64-linux" = "linux-amd64";
      "aarch64-darwin" = "darwin-arm64";
    };
    # Each release asset is a distinct binary, so hashes are per-platform.
    sha256Map = {
      "linux-amd64" = "sha256-HHT/X8KLGJHTK2f0NIqbf3UJRrbUpyHpCRh6hIhoAWs=";
      "darwin-arm64" = "sha256-or2c7f5ea9uJMqAWRFhaD7pEYEP2nuFGhWsBNypOQVk=";
    };
    platform = platformMap.${system} or (throw "gh-aw overlay: unsupported system ${system}");
  in {
    overlayAttrs = {
      gh-aw = pkgs.stdenv.mkDerivation {
        pname = "gh-aw";
        version = "0.89.21";

        src = pkgs.fetchurl {
          url = "https://github.com/github/gh-aw/releases/download/v0.89.21/${platform}";
          sha256 = sha256Map.${platform};
        };

        dontUnpack = true;

        installPhase = ''
          install -Dm755 $src $out/bin/gh-aw
        '';

        meta = {
          description = "GitHub Agentic Workflows";
          homepage = "https://github.com/github/gh-aw";
        };
      };
    };
  };
}
