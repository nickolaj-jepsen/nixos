# Build every home-manager host's activationPackage in `just check` (nix flake
# check): a home-manager half that starts reading osConfig (null standalone) or
# a non-shared option fails CI here, not just on a future deploy.
#
# disko-templates: a template is copied verbatim into a host dir, where it must
# pass the host collector, so check the card shape at eval time.
#
# just-ask-lists: the justfile tags every verb agents must ask about with
# `[metadata('ask')]`; both agent permission files must pin exactly that set.
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
    && lib.assertMsg (lib.hasInfix "@@DISK@@" (builtins.readFile path)) "${name}: missing the @@DISK@@ sentinel that marks the device";
in {
  perSystem = {
    pkgs,
    system,
    ...
  }:
    lib.optionalAttrs (system == "x86_64-linux") {
      checks =
        lib.mapAttrs' (name: hc: lib.nameValuePair "${name}-home" hc.activationPackage) config.flake.homeConfigurations
        // {
          disko-templates = assert lib.all checkTemplate templates; pkgs.emptyFile;
          just-ask-lists =
            pkgs.runCommand "just-ask-lists" {
              nativeBuildInputs = [pkgs.just pkgs.jq];
            } ''
              just --justfile ${./justfile} --dump --dump-format json > dump.json
              jq -r '.recipes | to_entries[]
                | select(any(.value.attributes[]?; type == "object" and (.metadata // [] | index("ask"))))
                | .key' dump.json | sort -u > tagged
              sed -n 's/.*"just \([a-z0-9-]*\)[^"]*" = "ask";/\1/p' ${./modules/programs/pi/default.nix} | sort -u > pi
              sed -n 's/.*"Bash(just \([a-z0-9-]*\):[^"]*)"/\1/p' ${./modules/programs/claude-code/default.nix} | sort -u > claude
              for f in pi claude; do
                if ! diff -u --label "justfile [metadata('ask')]" --label "$f ask list" tagged "$f"; then
                  echo "error: tag the verb in the justfile and pin it in both ask lists" >&2
                  exit 1
                fi
              done
              touch $out
            '';
        };
    };
}
