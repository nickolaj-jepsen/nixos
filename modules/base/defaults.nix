{lib, ...}: {
  options.fireproof.base.defaults = {
    terminal = lib.mkOption {
      type = lib.types.str;
      description = "The terminal to use";
    };
  };
}
