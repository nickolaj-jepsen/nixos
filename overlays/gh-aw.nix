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
      "linux-amd64" = "sha256-KZ30/9u639GO1h6iSDt8yT0KIpLPynq4KvwbxyVy5ag=";
      "linux-arm64" = "sha256-QwSKUYDbYNsqqL2B1BF4XLFWB4skuacQhFmZCU0oTRQ=";
      "darwin-amd64" = "sha256-t/TMEMIfbbQRocI/fqRk+w6xcUmwQNPSEa+zQm1Ok6I=";
      "darwin-arm64" = "sha256-3KKe61dFObZ1N7DL4iPEiw6cnOG5Fg7jsHEy0ZC9uto=";
    };
    platform = platformMap.${system};
  in {
    overlayAttrs = {
      gh-aw = pkgs.stdenv.mkDerivation {
        pname = "gh-aw";
        version = "0.82.14";

        src = pkgs.fetchurl {
          url = "https://github.com/github/gh-aw/releases/download/v0.82.14/${platform}";
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
