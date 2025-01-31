{
  inputs,
  pkgs,
  ...
}: let
  packageName = "astal";

  package = inputs.ags.lib.bundle {
    inherit pkgs;
    src = ./src;
    name = packageName;
    gtk4 = true;
    entry = "app.ts";
    extraPackages = with inputs.ags.packages.${pkgs.system}; [
      battery
      bluetooth
      hyprland
      network
      tray
      notifd
      mpris
      wireplumber
    ];
  };
in {
  user.home-manager = {
    systemd.user.services.astal = {
      Unit = {
        Description = "Astal";
        Documentation = "https://github.com/Aylur/astal";
        After = ["graphical-session.target"];
      };

      Service = {
        ExecStart = "${package}/bin/${packageName}";
        Restart = "on-failure";
        KillMode = "mixed";
        Slice = "app-graphical.slice";
      };

      Install = {
        WantedBy = ["graphical-session.target"];
      };
    };
  };
}
