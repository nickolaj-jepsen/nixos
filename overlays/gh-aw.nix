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
      "linux-amd64" = "sha256-AI9Pt0xGpf40tiCcQJ4wCM9sQOR+nY6fKSwWBGREeD4=";
      "linux-arm64" = "sha256-jl4ifAB4ghM5KUs+bRcvf8MN6mQaubNVU0Iww0+4ntE=";
      "darwin-amd64" = "sha256-sgju/kJ18n5D5AbbJqCVwNoD7Kje3Epu8TR1AAcvkLM=";
      "darwin-arm64" = "sha256-sQxyHil5vYXLWV3vCe4iVG8/zuwdBdJg9fq9onImGjA=";
    };
    platform = platformMap.${system};
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
