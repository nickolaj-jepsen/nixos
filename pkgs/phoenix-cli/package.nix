{
  buildNpmPackage,
  importNpmLock,
  lib,
  makeWrapper,
  nodejs,
}: let
  manifest = lib.importJSON ./package.json;
in
  buildNpmPackage {
    pname = "phoenix-cli";
    version = manifest.dependencies."@arizeai/phoenix-cli";
    src = ./.;
    npmDeps = importNpmLock {npmRoot = ./.;};
    inherit (importNpmLock) npmConfigHook;
    nativeBuildInputs = [makeWrapper];
    npmFlags = ["--legacy-peer-deps"];
    dontNpmBuild = true;
    installPhase = ''
      runHook preInstall
      mkdir -p "$out/lib" "$out/bin"
      cp -r node_modules "$out/lib/"
      rm -f "$out/lib/node_modules/.package-lock.json"
      cli="$out/lib/node_modules/@arizeai/phoenix-cli/build"
      makeWrapper ${lib.getExe nodejs} "$out/bin/px" --add-flags "$cli/index.js"
      makeWrapper ${lib.getExe nodejs} "$out/bin/pxi" --add-flags "$cli/pxi/index.js"
      ln -s px "$out/bin/phoenix-cli"
      runHook postInstall
    '';
    meta.mainProgram = "px";
  }
