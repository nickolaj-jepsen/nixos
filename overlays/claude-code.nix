{inputs, ...}: {
  perSystem = {system, ...}: let
    pkgsUnstable = import inputs.nixpkgs-unstable {
      inherit system;
      config.allowUnfree = true;
    };
  in {
    overlayAttrs = {
      claude-code = pkgsUnstable.claude-code-bin.overrideAttrs (_oldAttrs: rec {
        version = "2.1.62";
        src = pkgsUnstable.fetchurl {
          url = "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/${version}/linux-x64/claude";
          sha256 = "d6f0726cb8e94b7a30c243964529ba9135e642c40d2134ca09f5f845071471b4";
        };
      });
    };
  };
}
