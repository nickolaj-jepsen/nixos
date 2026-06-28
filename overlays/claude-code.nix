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
          hash = "sha256-yfBNkp8YvZoQHziX8n3k4eDxXr6EANSq8CmD1z3Wax0=";
        };
        aarch64-linux = {
          dir = "linux-arm64";
          hash = "sha256-OUVM5i55XutIcagfZFPNqW6Sbi25pN1B0OwbYLAVNEg=";
        };
        x86_64-darwin = {
          dir = "darwin-x64";
          hash = "sha256-y6XDvcqKtfjnWQQGcC1Bj2EU2bOfSPFodmgOiBq/Hug=";
        };
        aarch64-darwin = {
          dir = "darwin-arm64";
          hash = "sha256-91E6MDha2QGcI3Im/W7EZQizBi6+/Kiu2+OX0RGoGP8=";
        };
      }
      .${
        system
      } or (throw "claude-code overlay: unsupported system ${system}");
  in {
    overlayAttrs = {
      claude-code = pkgsUnstable.claude-code.overrideAttrs (oldAttrs: rec {
        version = "2.1.193";
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
