# Enabled when: desktop
{
  config,
  lib,
  ...
}: {
  config = lib.mkIf config.fireproof.desktop.enable {
    fireproof.home-manager.services.remmina.enable = true;
  };
}
