# fpLib as a flake-parts module arg: leaves take it at the file head and close over it.
{lib, ...}: {
  _module.args.fpLib = import ./. {inherit lib;};
}
