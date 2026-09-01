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
      "linux-amd64" = "sha256-FiT7Om6TtIBGN3x7JsmzJuKyUFaz82zD/Tvw6+59Wf0=";
      "linux-arm64" = "sha256-OC4a4PpT0M5Ju0vw2Shq8UmMPOsoTWFd5+9IxVLQDVI=";
      "darwin-amd64" = "sha256-ED+IsOpluecA8jdGC0HNCx+Ss7t3l/q/lDe47F/0LJE=";
      "darwin-arm64" = "sha256-EsNqgDeCL6xbeoshfuo/mPITEMLuTHrLKvfAW8DlBW4=";
    };
    platform = platformMap.${system};
  in {
    overlayAttrs = {
      gh-aw = pkgs.stdenv.mkDerivation {
        pname = "gh-aw";
        version = "0.87.10";

        src = pkgs.fetchurl {
          url = "https://github.com/github/gh-aw/releases/download/v0.87.10/${platform}";
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
