# Not in nixpkgs. The npm tarball ships a self-contained bundle (no runtime
# dependencies; its two peers are optional output formats), so it only needs node.
{
  lib,
  stdenvNoCC,
  fetchurl,
  makeWrapper,
  nodejs,
}:
stdenvNoCC.mkDerivation rec {
  pname = "chrome-devtools-mcp";
  version = "1.12.0";
  src = fetchurl {
    url = "https://registry.npmjs.org/chrome-devtools-mcp/-/chrome-devtools-mcp-${version}.tgz";
    # npm's dist.integrity, which the updater copies as-is.
    hash = "sha512-lAGpH0zXT1ZdaPefP1KK/MvxwihOlu7VGQ7p4wbhD9OhN17vUC4KWk/ImUYR9DE4s+7r4r0ySV4xr2OkTa7ZMA==";
  };
  nativeBuildInputs = [makeWrapper];
  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib/${pname}
    cp -r . $out/lib/${pname}
    makeWrapper ${lib.getExe nodejs} $out/bin/${pname} \
      --add-flags $out/lib/${pname}/build/src/bin/${pname}.js
    runHook postInstall
  '';
  meta = {
    description = "MCP server for Chrome DevTools";
    homepage = "https://github.com/ChromeDevTools/chrome-devtools-mcp";
    license = lib.licenses.asl20;
    mainProgram = pname;
  };
}
