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
      "linux-amd64" = "sha256-f4NFWEy24vJrvcrtXbky75xckbyXRbbw8+U7KAojb88=";
      "linux-arm64" = "sha256-vKCwKpAXacz2ogNgBQgFKywVVkFP0pxMEeDMPaW1Pl4=";
      "darwin-amd64" = "sha256-yBI3Nq1X0DAGl3TLDayION60IZFxdmzSRjJfqK6TW08=";
      "darwin-arm64" = "sha256-cX2+Ty7H9o28kkrQe2EQeSEPWlbiwzpnflax+tFMkJc=";
    };
    platform = platformMap.${system};
  in {
    overlayAttrs = {
      gh-aw = pkgs.stdenv.mkDerivation {
        pname = "gh-aw";
        version = "0.87.8";

        src = pkgs.fetchurl {
          url = "https://github.com/github/gh-aw/releases/download/v0.87.8/${platform}";
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
