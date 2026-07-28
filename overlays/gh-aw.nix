_: {
  perSystem = {
    pkgs,
    system,
    ...
  }: let
    platformMap = {
      "x86_64-linux" = "linux-amd64";
      "aarch64-linux" = "linux-arm64";
      "x86_64-darwin" = "darwin-amd64";
      "aarch64-darwin" = "darwin-arm64";
    };
    # Each release asset is a distinct binary, so hashes are per-platform.
    sha256Map = {
      "linux-amd64" = "sha256-RBURg/1eLvmwwCTj9CMlUbq8ZggMzmA4eCyCRV3MGkQ=";
      "linux-arm64" = "sha256-u8Q5cqpvycxU8twPdWDnytjjRQV4AJtsmVPFpMPsVYc=";
      "darwin-amd64" = "sha256-SNthLZXflH7yQrYt2wFocXj8T/qignjysSsBDKELwEY=";
      "darwin-arm64" = "sha256-qK5W9RXFsmR4j+D2KEPDu5UCkoaCz2X0iGp/U1aO8Q4=";
    };
    platform = platformMap.${system};
  in {
    overlayAttrs = {
      gh-aw = pkgs.stdenv.mkDerivation {
        pname = "gh-aw";
        version = "0.83.4";

        src = pkgs.fetchurl {
          url = "https://github.com/github/gh-aw/releases/download/v0.83.4/${platform}";
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
