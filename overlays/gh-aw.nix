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
      "linux-amd64" = "sha256-Ijc+FTDxPxxJGpaPwpPe2lP/JUgivharNF78b00z++U=";
      "linux-arm64" = "sha256-ZeoU99xrWk9P7j/FiNkx7X/+u/W5VbIT65IlHwyAenA=";
      "darwin-amd64" = "sha256-jYnBDejC4I6YlTxPRuD/l8rUB6Ek0D8Gytd+vcJgppY=";
      "darwin-arm64" = "sha256-V5m+ABvrUYwUkZx8kG+IQgUvrTZ7ecaqk0tgeYJrG3k=";
    };
    platform = platformMap.${system};
  in {
    overlayAttrs = {
      gh-aw = pkgs.stdenv.mkDerivation {
        pname = "gh-aw";
        version = "0.80.9";

        src = pkgs.fetchurl {
          url = "https://github.com/github/gh-aw/releases/download/v0.80.9/${platform}";
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
