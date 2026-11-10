# niri's overview for Hyprland; not in nixpkgs. Built against the Hyprland the session runs.
{
  unstable,
  inputs,
  lib,
}:
unstable.hyprlandPlugins.mkHyprlandPlugin {
  pluginName = "scrolloverview";
  version = "0-unstable-${inputs.hyprland-scroll-overview.lastModifiedDate or "0"}";
  src = inputs.hyprland-scroll-overview;

  buildInputs = [unstable.lua5_4];
  dontUseCmakeConfigure = true;
  buildPhase = ''
    runHook preBuild
    make all
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    install -Dm755 scrolloverview.so $out/lib/libscrolloverview.so
    runHook postInstall
  '';

  meta = {
    description = "Scrollable workspace overview plugin for Hyprland";
    homepage = "https://github.com/yayuuu/hyprland-scroll-overview";
    license = lib.licenses.bsd3;
    platforms = lib.platforms.linux;
  };
}
