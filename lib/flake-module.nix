# fpLib as a flake-parts module arg: leaves take it at the file head and close over it.
{
  config,
  lib,
  ...
}: {
  _module.args.fpLib = import ./. {inherit lib;};

  # Every real host's top-level drvPath by name, whatever its class: `just eval` / `just same-drvs`.
  flake.hostDrvPaths = let
    inherit (config.flake) nixosConfigurations darwinConfigurations homeConfigurations;
  in
    lib.mapAttrs (_: c: c.config.system.build.toplevel.drvPath)
    (lib.filterAttrs (n: _: !lib.hasPrefix "bootstrap" n) nixosConfigurations)
    // lib.mapAttrs (_: c: c.system.drvPath) darwinConfigurations
    // lib.mapAttrs (_: c: c.activationPackage.drvPath) homeConfigurations;
}
