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
          hash = "sha256-aDLcPxeXuJC3ERbl8tu/moP9PQSYwjW0sPnNDm5JmtY=";
        };
        aarch64-linux = {
          dir = "linux-arm64";
          hash = "sha256-20czVTLLyrZ6SzqxbY8/d5dr+F1Tx9efgpZTiqIr/OY=";
        };
        x86_64-darwin = {
          dir = "darwin-x64";
          hash = "sha256-FEhPuaBIC2tjgjBoWn2aJIpTObOEoWLg3xJ+SkoHJJs=";
        };
        aarch64-darwin = {
          dir = "darwin-arm64";
          hash = "sha256-dDJRG6O+gY4B8j9u74Yw0hSothhFHhiMPH1hqYfu9sc=";
        };
      }
      .${
        system
      } or (throw "claude-code overlay: unsupported system ${system}");
  in {
    overlayAttrs = {
      claude-code = pkgsUnstable.claude-code.overrideAttrs (oldAttrs: rec {
        version = "2.1.227";
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
