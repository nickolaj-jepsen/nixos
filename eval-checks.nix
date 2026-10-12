# Eval-only checks: forced in CI's `check` job (ci-build.sh over checks.x86_64-linux),
# which update triage maps failures back from.
#
# flake-eval: what `nix flake check` evaluated beyond the hosts the build matrix
# already covers (bootstrap ISOs, packages, the devshell), so CI evaluates each
# real host once instead of twice.
{
  config,
  lib,
  ...
}: let
  inherit (config) flake;
  bootstrap = lib.filterAttrs (n: _: lib.hasPrefix "bootstrap" n) flake.nixosConfigurations;
in {
  perSystem = {
    config,
    pkgs,
    system,
    ...
  }:
    lib.optionalAttrs (system == "x86_64-linux") {
      checks.flake-eval = pkgs.writeText "flake-eval" (builtins.unsafeDiscardStringContext (lib.concatLines (
        lib.mapAttrsToList (n: c: "${n} ${c.config.system.build.toplevel.drvPath}") bootstrap
        ++ lib.mapAttrsToList (n: p: "packages.${n} ${p.drvPath}") config.packages
        ++ lib.mapAttrsToList (n: d: "devShells.${n} ${d.drvPath}") config.devShells
      )));
    };
}
