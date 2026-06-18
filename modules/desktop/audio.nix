{
  flake.modules.nixos.audio = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.fireproof.desktop.enable {
      security.rtkit.enable = true;
      # NixOS auto-enables speechd on graphical hosts; no screen-reader use here, so drop it and its mbrola/espeak voice closure (~760 MiB).
      services.speechd.enable = false;
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
  };
}
