{
  config,
  lib,
  pkgs,
  ...
}: let
  screenshotPkg = pkgs.writeShellScriptBin "screenshot" ''
    AREA=$(${lib.getExe pkgs.slurp} -d)
    ${lib.getExe pkgs.grim} -t ppm -g "$AREA" - | ${lib.getExe pkgs.satty} -f - --initial-tool=arrow --early-exit --copy-command=${pkgs.wl-clipboard}/bin/wl-copy --action-on-enter="save-to-clipboard" --disable-notifications
  '';
in {
  config = lib.mkIf config.fireproof.desktop.enable {
    environment.systemPackages = [
      screenshotPkg
    ];
  };
}
