{
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

    config = {
      services."0xcb-media-host" = {
        enable = true;
        inherit (cfg) serialDevice;
        extraArgs = lib.optionals (cfg.mprisPlayer != null) ["--mpris-player" cfg.mprisPlayer];
      };

      users.extraGroups.dialout.members = [username];
    };
  };
}
