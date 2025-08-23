{
  pkgs,
  lib,
  ...
}: let
  screenshotPkg = pkgs.writeShellScriptBin "screenshot" ''
    AREA=$(${lib.getExe pkgs.slurp} -d)
    ${lib.getExe pkgs.grim} -t ppm -g "$AREA" - | ${lib.getExe pkgs.satty} -f - --initial-tool=arrow --copy-command=${pkgs.wl-clipboard}/bin/wl-copy --action-on-enter="save-to-clipboard" --disable-notifications
  '';
in {
  environment.systemPackages = [
    screenshotPkg
  ];
}
