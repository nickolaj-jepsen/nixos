# Aspect: oxcb-media
{
  flake.aspectTags.oxcb-media = ["oxcb-media"];

  flake.modules.nixos.oxcb-media = {
    config,
    lib,
    inputs,
    ...
  }: let
    cfg = config.fireproof.desktop.oxcbMedia;
    inherit (config.fireproof) username;
  in {
    imports = [inputs.zero-x-cb-media.nixosModules.default];

    options.fireproof.desktop.oxcbMedia = {
      enable = lib.mkEnableOption "0xCB-media host daemon (bridges MPRIS + PipeWire to the 0xCB-1337 macropad over USB CDC ACM)";
      serialDevice = lib.mkOption {
        type = lib.types.str;
        default = "/dev/ttyACM0";
        description = "CDC ACM serial device the macropad enumerates as.";
      };
      mprisPlayer = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "org.mpris.MediaPlayer2.spotify";
        description = "Pin the daemon to a specific MPRIS player. Null lets the daemon pick automatically.";
      };
    };

    config = lib.mkIf cfg.enable {
      services."0xcb-media-host" = {
        enable = true;
        inherit (cfg) serialDevice;
        extraArgs = lib.optionals (cfg.mprisPlayer != null) ["--mpris-player" cfg.mprisPlayer];
      };

      users.extraGroups.dialout.members = [username];
    };
  };
}
