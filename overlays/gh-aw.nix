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
      "linux-amd64" = "sha256-+cqhCrlIrCIo/129DlEJ6aKs+CChbM/wxPMx7b43MFc=";
      "linux-arm64" = "sha256-aYo0LGslfqWgW0SpaPtrXoMqOlIaxoHX4RHz5SmGw4E=";
      "darwin-amd64" = "sha256-VVmRlgX5kXrDz4NZ5Upxp6vAK377TPq10LE3fbR5nik=";
      "darwin-arm64" = "sha256-NjoH24pdQim8kAu40cYWCpy2Dy4gxME2+v8t/qPegRA=";
    };
    platform = platformMap.${system};
  in {
    overlayAttrs = {
      gh-aw = pkgs.stdenv.mkDerivation {
        pname = "gh-aw";
        version = "0.88.2";

        src = pkgs.fetchurl {
          url = "https://github.com/github/gh-aw/releases/download/v0.88.2/${platform}";
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
