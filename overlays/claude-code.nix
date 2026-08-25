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
          hash = "sha256-Fq0rlN6veymr7ZZtmByZkaR68EIPW+jtSj+Dvqn2eLw=";
        };
        aarch64-linux = {
          dir = "linux-arm64";
          hash = "sha256-0NopkwPXEKfMXN7OlimVj1EozhpyfhVGPGUe1c84XH8=";
        };
        x86_64-darwin = {
          dir = "darwin-x64";
          hash = "sha256-3gRLtUPoJjUvMVh6dDVuGy2ulNwbnJYKNi2fB9+Wwqc=";
        };
        aarch64-darwin = {
          dir = "darwin-arm64";
          hash = "sha256-n3wiYCUXZaGNCzUZhmnazBkS9ugSmjsB9rWNkzZf8fE=";
        };
      }
      .${
        system
      } or (throw "claude-code overlay: unsupported system ${system}");
  in {
    overlayAttrs = {
      claude-code = pkgsUnstable.claude-code.overrideAttrs (oldAttrs: rec {
        version = "2.1.245";
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
