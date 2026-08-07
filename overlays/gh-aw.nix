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
      "linux-amd64" = "sha256-wrrJnxAWePdHQDIPgpbAiwMLEgJ/Xk5NS7k+6AqMc6A=";
      "linux-arm64" = "sha256-k/oS1lnQ72jyRGhKwegj91Zkvh+9ZbxleSuLlM0qpjY=";
      "darwin-amd64" = "sha256-If5PX++K53n1P87OBDlCXMBhpSTdPZyOkWgjM5kfoeM=";
      "darwin-arm64" = "sha256-ZDkeI1r1jv/QEqnMRylamJ22HVPUobQpXxaSwcUvguA=";
    };
    platform = platformMap.${system};
  in {
    overlayAttrs = {
      gh-aw = pkgs.stdenv.mkDerivation {
        pname = "gh-aw";
        version = "0.85.4";

        src = pkgs.fetchurl {
          url = "https://github.com/github/gh-aw/releases/download/v0.85.4/${platform}";
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
