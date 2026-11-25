# Use the checked release bundle, never upstream's layout-editing installer.
{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  makeWrapper,
  coreutils,
  git,
}: let
  targets = {
    x86_64-linux = {
      triple = "x86_64-unknown-linux-gnu";
      hash = "0a641c8c2e9270daa0e5917e7509e3b343fe2f6ad02b06af1730632d2548269f";
    };
    aarch64-linux = {
      triple = "aarch64-unknown-linux-gnu";
      hash = "14a10da5b25595b542b86a7b2d7a5125cf8f21288ac2ac63dcaa9d6272f03b03";
    };
    x86_64-darwin = {
      triple = "x86_64-apple-darwin";
      hash = "df4a82a245445d4b3e29e01013d952c9b78e4eeaa9268352f2b613e0c076159a";
    };
    aarch64-darwin = {
      triple = "aarch64-apple-darwin";
      hash = "6cb6617616aebd4916180921771463cfe2f1056658a95d08225541fe5dc7ae9b";
    };
  };
  target = targets.${stdenv.hostPlatform.system};
in
  stdenv.mkDerivation rec {
    pname = "herdr-gitview";
    version = "0.6.0";
    src = fetchurl {
      url = "https://github.com/ChmaraX/herdr-gitview/releases/download/v${version}/herdr-gitview-app-${target.triple}.tar.gz";
      sha256 = target.hash;
    };
    nativeBuildInputs = [makeWrapper] ++ lib.optionals stdenv.isLinux [autoPatchelfHook];
    buildInputs = lib.optionals stdenv.isLinux [stdenv.cc.cc.lib];
    dontBuild = true;
    postPatch = ''
      substituteInPlace herdr-app/mods/*/engine.js \
        --replace-fail '"/usr/bin/env"' '"${lib.getExe' coreutils "env"}"'
    '';
    installPhase = ''
      runHook preInstall
      install -Dm755 bin/herdr-gitview $out/bin/herdr-gitview
      mkdir -p $out/share/herdr-gitview
      cp -rL herdr-app/mods $out/share/herdr-gitview/
      wrapProgram $out/bin/herdr-gitview --prefix PATH : ${lib.makeBinPath [git]}
      runHook postInstall
    '';
    doInstallCheck = true;
    installCheckPhase = ''
      ${lib.getExe git} init --quiet smoke
      $out/bin/herdr-gitview json status --repo "$PWD/smoke"
    '';
    meta = {
      description = "Git review, staging and diff panels for Herdr";
      homepage = "https://github.com/ChmaraX/herdr-gitview";
      license = lib.licenses.mit;
      platforms = builtins.attrNames targets;
      mainProgram = "herdr-gitview";
      sourceProvenance = [lib.sourceTypes.binaryNativeCode];
    };
  }
