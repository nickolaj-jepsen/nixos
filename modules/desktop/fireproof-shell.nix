{config, inputs, pkgs, ...}: let 
  primaryMonitorName =
    if builtins.length config.monitors > 0
    then (builtins.elemAt config.monitors 0).name
    else "";
in {
  environment.systemPackages = [
    inputs.fireproof-shell.packages.${pkgs.system}.fireproof-shell
  ];
  programs.fireproof-shell = {
    enable = true;
    systemd = true;
    monitor.primary = primaryMonitorName;
  };
}