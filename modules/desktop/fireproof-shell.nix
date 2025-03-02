{
  config,
  inputs,
  pkgs,
  pkgsUnstable,
  ...
}: let
  fireproofPkgs = inputs.fireproof-shell.packages.${pkgs.system};
in {
  environment.systemPackages = [
    fireproofPkgs.fireproof-shell
    fireproofPkgs.fireproof-ipc
    pkgsUnstable.astal.io
  ];
  programs.fireproof-shell = {
    enable = true;
    settings = {
      monitor.main = (builtins.head config.monitors).name or "";
      launcher.uwsm = true;
    };
  };

  fireproof.home-manager.wayland.windowManager.hyprland.settings.execr = ["pkill .fireproof-shel; fireproof-shell"];
}
