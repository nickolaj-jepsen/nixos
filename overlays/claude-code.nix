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
          hash = "sha256-1TWYXmlBo+sAF5zNf1LOsMZiOgMFpRjrxOZRT4SpTJk=";
        };
        aarch64-linux = {
          dir = "linux-arm64";
          hash = "sha256-eFLxrg77ZNRtd6V9iFLa3cSm/7WK7aYme9PzQorcCbM=";
        };
        x86_64-darwin = {
          dir = "darwin-x64";
          hash = "sha256-Q0hLE1LO8DoING827wQ3dVsarWRquTE84YeFe3lLckc=";
        };
        aarch64-darwin = {
          dir = "darwin-arm64";
          hash = "sha256-JmQAYhlJe/cCGsQxVlGc1C7aZM6ypm9DTsq4Pngx+UI=";
        };
      }
      .${
        system
      } or (throw "claude-code overlay: unsupported system ${system}");
  in {
    overlayAttrs = {
      claude-code = pkgsUnstable.claude-code.overrideAttrs (oldAttrs: rec {
        version = "2.1.228";
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
