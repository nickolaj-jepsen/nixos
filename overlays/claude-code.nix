{inputs, ...}: {
  perSystem = {system, ...}: let
    pkgsUnstable = import inputs.nixpkgs-unstable {
      inherit system;
      config.allowUnfree = true;
    };
  in {
    overlayAttrs = {
      claude-code = pkgsUnstable.claude-code-bin.overrideAttrs (_oldAttrs: rec {
        version = "2.1.56";
        src = pkgsUnstable.fetchurl {
          url = "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/${version}/linux-x64/claude";
          sha256 = "e139d71f9dec4d86308341b16d00c24441c789d0156852364a4c7dcf3f2e9b3e";
        };
      });
    };
  };
}
