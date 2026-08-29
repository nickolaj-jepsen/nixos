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
      "linux-amd64" = "sha256-uP0QDR1Wp3uEKtKDdf82EhWlqhJ322uaBdcAVM3nJg4=";
      "linux-arm64" = "sha256-H3BXDvJCSNN6Pmgz53r1tDD0bruYwsUi8+DcH5O6/aY=";
      "darwin-amd64" = "sha256-L97Yuy6lz05iLB2bBJ9n2XzmgE7RdK9etysaUifL0pQ=";
      "darwin-arm64" = "sha256-6jjQK2Em/+mgwAYRHysX1qNgJP+L8JwybkSKhTfYrZM=";
    };
    platform = platformMap.${system};
  in {
    overlayAttrs = {
      gh-aw = pkgs.stdenv.mkDerivation {
        pname = "gh-aw";
        version = "0.86.2";

        src = pkgs.fetchurl {
          url = "https://github.com/github/gh-aw/releases/download/v0.86.2/${platform}";
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
