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
          hash = "sha256-o0gJpoOf3v/yG5NH1/tba1jmqcwgil5ihT8pyD6xB6M=";
        };
        aarch64-linux = {
          dir = "linux-arm64";
          hash = "sha256-hrLqs004LHtCj8Lp9Ml/BORoBelQWCRyoT631I3mBRY=";
        };
        x86_64-darwin = {
          dir = "darwin-x64";
          hash = "sha256-GIkoepLSU1aui9jY5nsRRWAVUW7oukJ3oMcHR4bEm7Y=";
        };
        aarch64-darwin = {
          dir = "darwin-arm64";
          hash = "sha256-oIUtdq/EezD1ywt2JeyadxTLGJ8u7vbCjHfivpVPt/0=";
        };
      }
      .${
        system
      } or (throw "claude-code overlay: unsupported system ${system}");
  in {
    overlayAttrs = {
      claude-code = pkgsUnstable.claude-code.overrideAttrs (oldAttrs: rec {
        version = "2.1.201";
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
