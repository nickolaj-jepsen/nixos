# Build the dev-ao standalone home-manager host in `just check` (nix flake
# check) — the role the old portability-check served: a home-manager half that
# starts reading osConfig (null standalone) or a non-shared option fails CI
# here, not just on a future deploy. dev-ao is a real discovered host
# (hosts/dev-ao), so this only forces its activationPackage on the build host.
#
# disko-templates: bootstrap-install copies a template verbatim into a host dir,
# where it must pass the host collector, so check the card shape at eval time.
#
# lock-hygiene: every nixpkgs in flake.lock is one of our root inputs, so an
# input that grows its own nixpkgs fails here (add a follows) instead of quietly
# doubling eval time and the closure. Update triage reverts the input that added it.
{
  config,
  lib,
  ...
}: let
  templateDir = ./hosts/_templates/disko;
  templates = lib.filter (lib.hasSuffix ".nix") (lib.attrNames (builtins.readDir templateDir));
  cardKeys = config.flake.hostCardKeys;
  checkTemplate = name: let
    path = templateDir + "/${name}";
    card = import path;
  in
    lib.assertMsg (builtins.isAttrs card) "${name}: must be a host card (attrset), not a module"
    && lib.assertMsg (lib.subtractLists cardKeys (lib.attrNames card) == []) "${name}: keys must be within {${lib.concatStringsSep ", " cardKeys}}"
    && lib.assertMsg (lib.hasAttrByPath ["nixos" "disko" "devices"] card) "${name}: must define nixos.disko.devices"
    && lib.assertMsg (lib.hasInfix "@@DISK@@" (builtins.readFile path)) "${name}: missing the @@DISK@@ sentinel bootstrap-install substitutes";

  lock = lib.importJSON ./flake.lock;
  rootNodes = lib.attrValues lock.nodes.root.inputs;
  strayNixpkgs = lib.attrNames (lib.filterAttrs
    (n: v: lib.toLower (v.original.repo or "") == "nixpkgs" && !lib.elem n rootNodes)
    lock.nodes);
in {
  perSystem = {
    pkgs,
    system,
    ...
  }:
    lib.optionalAttrs (system == "x86_64-linux") {
      checks.dev-ao-home = config.flake.homeConfigurations.dev-ao.activationPackage;
      checks.disko-templates = assert lib.all checkTemplate templates; pkgs.emptyFile;
      checks.lock-hygiene = assert lib.assertMsg (strayNixpkgs == [])
      "flake.lock has nixpkgs not followed from the root: ${lib.concatStringsSep ", " strayNixpkgs} (add `<input>.inputs.nixpkgs.follows = \"nixpkgs\"`)";
        pkgs.emptyFile;
    };
}
