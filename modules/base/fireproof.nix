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
  };
}
