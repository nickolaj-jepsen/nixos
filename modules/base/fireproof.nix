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
    hardware = {
      battery = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable battery support (UPower, battery widget, etc.)";
      };
    };
  };
}
