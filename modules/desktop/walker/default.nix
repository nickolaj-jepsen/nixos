{
  inputs,
  pkgs,
  lib,
  config,
  ...
}: {
  environment.systemPackages = [
    inputs.walker.packages.${pkgs.system}.walker
  ];
  fireproof.home-manager = {
    imports = [inputs.walker.homeManagerModules.default];
    programs.walker = {
      enable = true;
      runAsService = true;
      theme = import ./theme.nix;

      config = {
        app_launch_prefix = "${lib.getExe config.programs.uwsm.package} app -- ";
      };
    };
  };
}
