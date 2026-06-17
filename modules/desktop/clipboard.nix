{
  flake.aspectTags.clipboard = ["desktop"];
  flake.modules.homeManager.clipboard = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.fireproof.desktop.enable {
      home.packages = [pkgs.wl-clipboard];
    };
  };
}
