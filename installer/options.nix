{lib, ...}: {
  options.installer.targetHost = lib.mkOption {
    type = lib.types.str;
    default = "";
    description = "Host this ISO installs. Empty = the generic, non-host-specific installer.";
  };
}
