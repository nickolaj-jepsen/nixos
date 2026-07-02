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
      "linux-amd64" = "sha256-iMYs6F56WMokYkJq64zmdx2f1yz+ZR8wRMk9+6vvS/g=";
      "linux-arm64" = "sha256-RXS3HTDM6YWyPIk+HNqTSJn0T/v5Zu7ZESU87x5P7Ag=";
      "darwin-amd64" = "sha256-mw/+DAGM1KolnQxDQqcIgjV9sATu63hcnM6+thfNgwE=";
      "darwin-arm64" = "sha256-B+ozoESs/h5Mh7r/RwOnIVQ1ykRWSbyGgEpzVKBPjZs=";
    };
    platform = platformMap.${system};
  in {
    overlayAttrs = {
      gh-aw = pkgs.stdenv.mkDerivation {
        pname = "gh-aw";
        version = "0.81.6";

        src = pkgs.fetchurl {
          url = "https://github.com/github/gh-aw/releases/download/v0.81.6/${platform}";
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
