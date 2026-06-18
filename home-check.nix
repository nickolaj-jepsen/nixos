# Build the dev-ao standalone home-manager host in `just check` (nix flake
# check) — the role the old portability-check served: a home-manager half that
# starts reading osConfig (null standalone) or a non-shared option fails CI
# here, not just on a future deploy. dev-ao is a real discovered host
# (hosts/dev-ao), so this only forces its activationPackage on the build host.
{
  config,
  lib,
  ...
}: {
  perSystem = {system, ...}:
    lib.optionalAttrs (system == "x86_64-linux") {
      checks.dev-ao-home = config.flake.homeConfigurations.dev-ao.activationPackage;
    };
}
