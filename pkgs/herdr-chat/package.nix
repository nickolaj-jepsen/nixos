# Upstream's release bundles the Node host and its dependencies. No npm install
# or upstream installer at activation time (the latter rewrites Herdr's layout).
{
  lib,
  stdenvNoCC,
  fetchurl,
  makeWrapper,
  nodejs,
  coreutils,
  git,
  perl,
  unstable,
}:
stdenvNoCC.mkDerivation rec {
  pname = "herdr-chat";
  version = "0.6.0";
  src = fetchurl {
    url = "https://github.com/ChmaraX/herdr-chat/releases/download/v${version}/herdr-chat-${version}.tar.gz";
    hash = "sha256-3qe08A7r7DUuaYtUKub7qlohWBt7AgCLJbeyN65cuKw=";
  };
  nativeBuildInputs = [makeWrapper];
  # Upstream has no provider allowlist. Only expose Codex in the launcher;
  # the generated connection config likewise supplies no Pi/Claude commands.
  postPatch = ''
    substituteInPlace herdr-app/mods/new-chat/main.js \
      --replace-fail '  { id: "pi", label: "Pi", icon: "pi", tint: true, letter: "p" },' "" \
      --replace-fail '  { id: "claude", label: "Claude Code", icon: "claude", letter: "c" },' ""
    # These run from the GUI, whose PATH need not be the interactive shell's.
    substituteInPlace herdr-app/mods/chat/hostpane.js \
      --replace-fail 'perl -MTime' '${lib.getExe perl} -MTime' \
      --replace-fail '| hc connect' '| ${lib.getExe' unstable.herdr-core "hc"} connect'
    substituteInPlace herdr-app/mods/chat/keymap.js \
      --replace-fail '"/bin/pwd"' '"${coreutils}/bin/pwd"'
  '';
  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib/herdr-chat $out/share/herdr-chat/mods
    cp -r host package.json $out/lib/herdr-chat/
    cp -r herdr-app/mods/{chat,new-chat} $out/share/herdr-chat/mods/
    makeWrapper ${lib.getExe nodejs} $out/bin/herdr-chat-host \
      --add-flags $out/lib/herdr-chat/host/main.js \
      --prefix PATH : ${lib.makeBinPath [git]}
    runHook postInstall
  '';
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    $out/bin/herdr-chat-host --help
    runHook postInstallCheck
  '';
  meta = {
    description = "Native Herdr chat host with a Codex-only launcher";
    homepage = "https://github.com/ChmaraX/herdr-chat";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
    mainProgram = "herdr-chat-host";
  };
}
