{
  config,
  pkgs,
  ...
}: let
  sleep_cmd = "${config.programs.hyprland.package}/bin/hyprctl dispatch dpms off";
  wake_cmd = "${config.programs.hyprland.package}/bin/hyprctl dispatch dpms on";
  lock_cmd = "pidof ${pkgs.hyprlock}/bin/hyprlock || ${pkgs.hyprlock}/bin/hyprlock";
in {
  config = {
    fireproof.home-manager.services.hypridle = {
      enable = true;
      settings = {
        general = {
          inherit lock_cmd;
          before_sleep_cmd = "${pkgs.systemd}/bin/loginctl lock-session";
          after_sleep_cmd = sleep_cmd;
        };
        listener = [
          {
            timeout = 60 * 5;
            on-timeout = lock_cmd;
          }
          {
            timeout = 60 * 15;
            on-timeout = sleep_cmd;
            on-resume = wake_cmd;
          }
        ];
      };
    };
  };
}
