{lib, ...}: {
  options.fireproof.default-apps = {
    terminal = lib.mkOption {
      type = lib.types.str;
      description = "The terminal to use";
    };
  };
}
