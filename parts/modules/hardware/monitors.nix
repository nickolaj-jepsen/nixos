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

        resolution = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "1920x1080";
        };

        refreshRate = lib.mkOption {
          type = lib.types.nullOr lib.types.int;
          default = null;
          example = 60;
        };

        position = lib.mkOption {
          type = lib.types.str;
          default = "0x0";
        };

        scale = lib.mkOption {
          type = lib.types.float;
          default = 1.0;
        };

        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
        };
      };
    });
    default = [{}];
  };
}
