{
  flake.modules.homeManager.clipboard = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf (config.fireproof.desktop.enable && pkgs.stdenv.isLinux) {
      home.packages = [pkgs.wl-clipboard];
    };
  };
}
