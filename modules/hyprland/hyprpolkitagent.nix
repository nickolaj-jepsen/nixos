{
  pkgs,
  ...
}: {
  config = {
    user.home-manager.systemd.user.services.hyprpolkitagent = {
      Unit = {
        Description = "Hyprland Polkit Authentication Agent";
      };

      Service = {
        Type = "simple";
        ExecStart = "${pkgs.hyprpolkitagent}/libexec/hyprpolkitagent";
        Restart = "on-failure";
        RestartSec = 1;
        TimeoutStopSec = 10;
        Slice = "session.slice";
      };

      Install = {
        WantedBy = ["graphical-session.target"];
      };
    };
  };
}
