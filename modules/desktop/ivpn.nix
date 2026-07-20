# IVPN client. The nixos half enables the upstream services.ivpn module (tun
# daemon + ivpn CLI; flips firewall reverse-path to "loose" so the VPN's routing
# survives). The home-manager half adds the desktop UI (Linux-only nixpkgs build).
{
  flake.modules.nixos.ivpn = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf config.fireproof.desktop.ivpn.enable {
      services.ivpn.enable = true;
    };
  };

  flake.modules.homeManager.ivpn = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf (config.fireproof.desktop.ivpn.enable && pkgs.stdenv.isLinux) {
      home.packages = [pkgs.ivpn-ui];
    };
  };
}
