_: {
  perSystem = {pkgs, ...}: {
    overlayAttrs = {
      claude-code =
        pkgs.claude-code.overrideAttrs
        (_oldAttrs: rec {
          version = "2.1.36";
          src = pkgs.fetchzip {
            url = "https://registry.npmjs.org/@anthropic-ai/claude-code/-/claude-code-${version}.tgz";
            hash = "sha256-fRNGD4+fL11gdwWrlHkFkzHt12Sy+sf2fcZrRhYM0d8=";
          };
        });
    };
  };
}
