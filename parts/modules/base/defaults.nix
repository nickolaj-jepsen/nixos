{lib, ...}: let
  inherit (lib) mkOption types;
in {
  options.defaults = {
    terminal = mkOption {
      type = types.nullOr types.str;
    };

    fileManager = mkOption {
      type = types.nullOr types.str;
    };

    browser = mkOption {
      type = types.nullOr types.str;
    };

    editor = mkOption {
      type = types.nullOr types.str;
    };
  };
}
