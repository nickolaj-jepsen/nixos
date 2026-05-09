{
  lib,
  pkgs,
  config,
  ...
}: {
  config = lib.mkIf config.fireproof.desktop.enable {
    security.rtkit.enable = true;
    services.pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      pulse.enable = true;
    };
    environment.systemPackages = [
      pkgs.pulseaudio # provides pactl
      pkgs.wireplumber # provides wpctl
      pkgs.alsa-utils # aplay/arecord
    ];
  };
}
