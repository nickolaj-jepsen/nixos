# Tracks a newer release than nixpkgs by swapping in upstream's release manifest
# (version + per-platform binary name and checksum); the package derives the
# download URL and arch from it, so no hashes live here.
{
  lib,
  unstable,
  sox,
}:
(unstable.claude-code.override {
  manifest = lib.importJSON ./manifest.zst.json;
}).overrideAttrs (oldAttrs: {
  postInstall =
    (oldAttrs.postInstall or "")
    + ''
      wrapProgram $out/bin/claude \
        --prefix PATH : ${lib.makeBinPath [sox]}
    '';
})
