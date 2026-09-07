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
  in {
    overlayAttrs = {
      # Track a newer release than nixpkgs by swapping in upstream's release
      # manifest (version + per-platform binary name and checksum); the package
      # derives the download URL and arch from it, so no hashes live here.
      claude-code =
        (pkgsUnstable.claude-code.override {
          manifest = pkgs.lib.importJSON ./claude-code-manifest.zst.json;
        })
        .overrideAttrs (oldAttrs: {
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
