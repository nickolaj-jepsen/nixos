{lib, ...}: {
  options.fireproof.base.defaults = {
    terminal = lib.mkOption {
      type = lib.types.str;
      default = "ghostty";
      description = "The terminal to use";
    };
  };
}
