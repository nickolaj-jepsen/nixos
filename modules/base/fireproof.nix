{lib, ...}: {
  options.fireproof = {
    hostname = lib.mkOption {
      type = lib.types.str;
      description = "The hostname of the machine";
    };
    username = lib.mkOption {
      type = lib.types.str;
      description = "The primary username for the machine";
    };
    work.enable = lib.mkEnableOption "Enable work-related applications and tools";
    dev.enable = lib.mkEnableOption "Enable development tools and applications";
    hardware = {
      battery = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable battery support (UPower, battery widget, etc.)";
      };
    };
  };
}
