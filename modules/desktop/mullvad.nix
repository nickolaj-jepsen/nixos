{
  flake.modules.nixos.mullvad = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.fireproof.desktop.mullvad.enable {
      services.mullvad-vpn = {
        enable = true;
        # GUI build, bundles daemon + CLI; the module default pkgs.mullvad is CLI-only.
        package = pkgs.mullvad-vpn;
      };
    };
  };
}
