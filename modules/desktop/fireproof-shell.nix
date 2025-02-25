{
  config,
  inputs,
  pkgs,
  ...
}: {
  environment.systemPackages = [
    inputs.fireproof-shell.packages.${pkgs.system}.fireproof-shell
  ];
  programs.fireproof-shell = {
    enable = true;
    systemd = true;
    monitor.primary = (builtins.head config.monitors).name or "";
  };
}
