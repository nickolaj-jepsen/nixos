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
      "linux-amd64" = "sha256-AI9Pt0xGpf40tiCcQJ4wCM9sQOR+nY6fKSwWBGREeD4=";
      "darwin-arm64" = "sha256-sQxyHil5vYXLWV3vCe4iVG8/zuwdBdJg9fq9onImGjA=";
    };
    platform = platformMap.${system} or (throw "gh-aw overlay: unsupported system ${system}");
  in {
    overlayAttrs = {
      gh-aw = pkgs.stdenv.mkDerivation {
        pname = "gh-aw";
        version = "0.88.8";

        src = pkgs.fetchurl {
          url = "https://github.com/github/gh-aw/releases/download/v0.88.8/${platform}";
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
