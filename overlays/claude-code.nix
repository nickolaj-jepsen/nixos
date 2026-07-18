{inputs, ...}: {
  perSystem = {
    system,
    pkgs,
    ...
  }: let
    pkgsUnstable = import inputs.nixpkgs-unstable {
      inherit system;
      config.allowUnfree = true;
    };
    # Upstream ships a prebuilt binary per platform; pick the one matching the
    # build system (the linux-x64 default broke aarch64-darwin: wrong-arch binary).
    plat =
      {
        x86_64-linux = {
          dir = "linux-x64";
          hash = "sha256-PAKRNvfIH1TtSjjp1S5lWq1TZDPbveUFGcjDG7ZGrRQ=";
        };
        aarch64-linux = {
          dir = "linux-arm64";
          hash = "sha256-5qzJIDHcf6V54H+TmdJWRcs54nv/cKZSAv39KVMEHII=";
        };
        x86_64-darwin = {
          dir = "darwin-x64";
          hash = "sha256-TDjyalekJhnugT8V3Dn8H6T+C7QDIVw83DQrWPponDw=";
        };
        aarch64-darwin = {
          dir = "darwin-arm64";
          hash = "sha256-WXlt0Y6dd/ElbzZ9ttKM5L2c1ZaOQCrToyeqw2q8bew=";
        };
      }
      .${
        system
      } or (throw "claude-code overlay: unsupported system ${system}");
  in {
    overlayAttrs = {
      claude-code = pkgsUnstable.claude-code.overrideAttrs (oldAttrs: rec {
        version = "2.1.214";
        src = pkgsUnstable.fetchurl {
          url = "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/${version}/${plat.dir}/claude";
          inherit (plat) hash;
        };
        nativeBuildInputs = (oldAttrs.nativeBuildInputs or []) ++ [pkgs.makeWrapper];
        postInstall =
          (oldAttrs.postInstall or "")
          + ''
            wrapProgram $out/bin/claude \
              --prefix PATH : ${pkgs.lib.makeBinPath [pkgs.sox]}
          '';
      });
    };
  };
}
