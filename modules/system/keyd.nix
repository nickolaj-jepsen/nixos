{
  flake.modules.nixos.keyd = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf config.fireproof.desktop.enable {
      services.keyd = {
        enable = lib.mkDefault true;
        keyboards.mouse = {
          # keyd prefix-matches ids (strstr), so leave off the trailing hash: it
          # derives from the node's name and capabilities and goes stale. `m:`
          # limits a match to pointer nodes, keeping Logitech keyboards and
          # headsets out. Vendor-only because a G502 X reports a different
          # product id per connection mode. `sudo keyd monitor` prints the ids.
          ids = [
            "m:046d" # Logitech mice (G502 X) — never a trackpad, or keyd breaks it
            "m:1ea7" # 2.4G wireless mouse
          ];
          settings = {
            main = {
              # Bind mouse back/forward to meta if held
              mouse1 = "overload(meta, mouse1)";
              mouse2 = "overload(meta, mouse2)";
            };
          };
        };
        keyboards.default = {
          ids = ["*"];
          settings = {
            main = {
              # Rebind capslock to backspace for all keyboards
              capslock = "backspace";
            };
          };
        };
      };
    };
  };
}
