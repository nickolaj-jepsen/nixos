# Not in nixpkgs. Pele is a library (no bin) with no runtime dependencies, so the
# npm tarball sits in a node_modules next to pele.mjs, the stdin-to-SVG CLI around it.
{
  lib,
  stdenvNoCC,
  fetchurl,
  makeWrapper,
  nodejs,
}:
stdenvNoCC.mkDerivation rec {
  pname = "pele";
  version = "1.13.0";
  src = fetchurl {
    url = "https://registry.npmjs.org/pele/-/pele-${version}.tgz";
    # npm's dist.integrity, which the updater copies as-is.
    hash = "sha512-Ie8UKY9x00MsuR3jO6AzUwzK2Z6MIV3Tf4EDdITiuk8Uaz8K7g0R082WqsqNaSU8DdgkrRvZThzhit83mi/uiw==";
  };
  nativeBuildInputs = [makeWrapper];
  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib/pele/node_modules
    cp -r . $out/lib/pele/node_modules/pele
    cp ${./pele.mjs} $out/lib/pele/pele.mjs
    makeWrapper ${lib.getExe nodejs} $out/bin/pele \
      --add-flags $out/lib/pele/pele.mjs
    runHook postInstall
  '';
  meta = {
    description = "Render Mermaid from stdin to a self-contained SVG with pele";
    homepage = "https://pele.run";
    license = lib.licenses.mit;
    mainProgram = "pele";
  };
}
