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
          hash = "sha256-3Yc0wLalA/4dF0JRhOV7OXwwuwM3oz8UcNmYX+v+Wwk=";
        };
        aarch64-linux = {
          dir = "linux-arm64";
          hash = "sha256-wYdMhbzTqItwQ5/VD/WRC35qxTccFN1J1MzCh4pZLQk=";
        };
        x86_64-darwin = {
          dir = "darwin-x64";
          hash = "sha256-Qpmj9IVR7zZfLQVvJNh+hLgixMELasxGl5RGt7XGDOs=";
        };
        aarch64-darwin = {
          dir = "darwin-arm64";
          hash = "sha256-M+KGJMWuhPK9fS2HYeXS53mXupZcsRtkSN5rbixWb5w=";
        };
      }
      .${
        system
      } or (throw "claude-code overlay: unsupported system ${system}");
  in {
    overlayAttrs = {
      claude-code = pkgsUnstable.claude-code.overrideAttrs (oldAttrs: rec {
        version = "2.1.205";
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
