# https://github.com/ChangeCaps/nixos-config/tree/0cec356abc0e46ca6ba27b3cf01cd51273bd4a69
{lib, ...}: {
  options.monitors = lib.mkOption {
    type = lib.types.listOf (lib.types.submodule {
      options = {
        name = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "DP-1";
        };

        resolution.width = lib.mkOption {
          type = lib.types.nullOr lib.types.int;
          default = null;
        };
        resolution.height = lib.mkOption {
          type = lib.types.nullOr lib.types.int;
          default = null;
        };

        refreshRate = lib.mkOption {
          type = lib.types.nullOr lib.types.int;
          default = null;
          example = 60;
        };

        refreshRateNiri = lib.mkOption {
          type = lib.types.nullOr lib.types.float;
          default = null;
          example = 60.0;
        };

        position.x = lib.mkOption {
          type = lib.types.int;
          default = 0;
        };
        position.y = lib.mkOption {
          type = lib.types.int;
          default = 0;
        };

        scale = lib.mkOption {
          type = lib.types.float;
          default = 1.0;
        };

        transform = lib.mkOption {
          # https://wiki.hyprland.org/Configuring/Monitors/#rotating
          type = lib.types.nullOr lib.types.int;
          default = null;
          example = 1;
        };

        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
        };
      };
    });
    default = [];
  };
}
