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
      "linux-amd64" = "sha256-F6o4PrwBlcw4W1Fm2ZTMeNnklZS2hE0xnoSmNzcrVJU=";
      "linux-arm64" = "sha256-5g7mQsHAV638nAwZMHhVloL6Od4rPEgraJg8nmd/ZJo=";
      "darwin-amd64" = "sha256-6cT6lr5zC3s0pCVFIFNWVjNFdueMLXDqes6rmX/lYp4=";
      "darwin-arm64" = "sha256-XOA/4FZLGUsZVXN4QX3JZyYjO9T8APDP2NNKG/8IwyM=";
    };
    platform = platformMap.${system};
  in {
    overlayAttrs = {
      gh-aw = pkgs.stdenv.mkDerivation {
        pname = "gh-aw";
        version = "0.84.3";

        src = pkgs.fetchurl {
          url = "https://github.com/github/gh-aw/releases/download/v0.84.3/${platform}";
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
