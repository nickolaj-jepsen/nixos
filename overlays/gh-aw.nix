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
      "linux-amd64" = "sha256-jDkoq/uwOmDs/9EeJjoPe0e3buhsMwSiD4ml4U9Zz4M=";
      "linux-arm64" = "sha256-z3+FbGLLSTG3zcriMhW+02HkLqInyxZ6aI95fe/59To=";
      "darwin-amd64" = "sha256-G3Kl90nWUI5hZKAzANQVx2J//vQ5GL5FtTegqPnCeqg=";
      "darwin-arm64" = "sha256-PdTEOh5jE6HCfPWoIZGBsB9cYPvTrTRwpie4LUAIjFY=";
    };
    platform = platformMap.${system};
  in {
    overlayAttrs = {
      gh-aw = pkgs.stdenv.mkDerivation {
        pname = "gh-aw";
        version = "0.83.1";

        src = pkgs.fetchurl {
          url = "https://github.com/github/gh-aw/releases/download/v0.83.1/${platform}";
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
