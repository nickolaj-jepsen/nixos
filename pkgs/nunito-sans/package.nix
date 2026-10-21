# Upstream variable TTFs only; nixpkgs' google-fonts override would fetch the whole ~3 GB google/fonts tree.
{
  lib,
  stdenvNoCC,
  fetchurl,
}: let
  # Upstream has no releases and last touched the fonts in 2023, so this stays hand-pinned.
  rev = "ee553a653282f0ff043660a01b78ab0f0d986437";
  # `[` is illegal in store names, hence the explicit `name`.
  fetchFont = file: name: hash:
    fetchurl {
      url = "https://raw.githubusercontent.com/googlefonts/NunitoSans/${rev}/fonts/variable/${file}";
      inherit name hash;
    };
in
  stdenvNoCC.mkDerivation {
    pname = "nunito-sans";
    version = "0-unstable-2023-03-31";

    srcs = [
      (fetchFont "NunitoSans%5BYTLC%2Copsz%2Cwdth%2Cwght%5D.ttf" "NunitoSans-Variable.ttf" "sha256-+TTXFC+0eEv4KNpIW33L2QwMgNUU6dSaXaDtOhriSR0=")
      (fetchFont "NunitoSans-Italic%5BYTLC%2Copsz%2Cwdth%2Cwght%5D.ttf" "NunitoSans-Italic-Variable.ttf" "sha256-2dXbGPPBEiGk+7VTy8cJORwReZZMfqpEZu9Dx4qkSS8=")
    ];
    dontUnpack = true;

    installPhase = ''
      runHook preInstall
      for src in $srcs; do
        install -Dm644 "$src" "$out/share/fonts/truetype/$(stripHash "$src")"
      done
      runHook postInstall
    '';

    meta = {
      description = "Nunito Sans variable font";
      homepage = "https://github.com/googlefonts/NunitoSans";
      license = lib.licenses.ofl;
      platforms = lib.platforms.all;
    };
  }
