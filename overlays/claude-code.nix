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
          hash = "sha256-4SBxdRqTNrivEBLBAzWP8ErBj5qv9Kc4z/e6XN+vY/I=";
        };
        aarch64-linux = {
          dir = "linux-arm64";
          hash = "sha256-KV/TBIG9A7OEUP3sKm4lu2RywgdPBLDEpWbNWYjyML8=";
        };
        x86_64-darwin = {
          dir = "darwin-x64";
          hash = "sha256-mGK3Sgg+ik7VcvmcvUiVGF4N1aCmAa/7D7jkPY0fQOY=";
        };
        aarch64-darwin = {
          dir = "darwin-arm64";
          hash = "sha256-cauv9ZMSyam2odgYNlBItC5OlcxSGoI2YO3tPgiA2bc=";
        };
      }
      .${
        system
      } or (throw "claude-code overlay: unsupported system ${system}");
  in {
    overlayAttrs = {
      claude-code = pkgsUnstable.claude-code.overrideAttrs (oldAttrs: rec {
        version = "2.1.218";
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
