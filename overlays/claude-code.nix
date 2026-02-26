{inputs, ...}: {
  perSystem = {system, ...}: let
    pkgsUnstable = import inputs.nixpkgs-unstable {
      inherit system;
      config.allowUnfree = true;
    };
  in {
    overlayAttrs = {
      claude-code = pkgsUnstable.claude-code-bin.overrideAttrs (_oldAttrs: rec {
        version = "2.1.59";
        src = pkgsUnstable.fetchurl {
          url = "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/${version}/linux-x64/claude";
          sha256 = "7a4a653982b07e0a8157f8d3b2c2f8e442520ab07b2fa2e692ba054dbba210c9";
        };
      });
    };
  };
}
