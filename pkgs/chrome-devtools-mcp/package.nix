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
  version = "1.13.0";
  src = fetchurl {
    url = "https://registry.npmjs.org/chrome-devtools-mcp/-/chrome-devtools-mcp-${version}.tgz";
    # npm's dist.integrity, which the updater copies as-is.
    hash = "sha512-Yf4qhS0+2oo7c+gOySMDHQt4ZL/yKXG2Mxxzjk0gcArINtcQ3tLiQVzAW6g2nsyQzAGhkcLwWWBAtlx3Bg+Spg==";
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
