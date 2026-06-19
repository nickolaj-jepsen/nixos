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
      "linux-amd64" = "sha256-04Ri+JgMYo3nG2++AGfkvUrWYO0Zl4afTylvAgkFWfA=";
      "linux-arm64" = "sha256-y/zQrK+Yt1taXDQJz4JEh/cTATIXbUTt9OnT9LHg9zU=";
      "darwin-amd64" = "sha256-RDpliYXbwJ6uqhdozhxEAIA0TJOEq9hmLxVJRXGxmC4=";
      "darwin-arm64" = "sha256-c97GolUiunXYzyoTGZ9rgcFQi3jpZcWjQV4lkWPFLIY=";
    };
    platform = platformMap.${system};
  in {
    overlayAttrs = {
      gh-aw = pkgs.stdenv.mkDerivation {
        pname = "gh-aw";
        version = "0.79.8";

        src = pkgs.fetchurl {
          url = "https://github.com/github/gh-aw/releases/download/v0.79.8/${platform}";
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
