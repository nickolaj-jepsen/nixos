# Generates Markdown reference docs for the custom `fireproof.*` options
# namespace from their `mkOption` declarations (description/type/default/example).
#
# Build with `just docs` (writes ./docs/fireproof-options.md) or
# `nix build .#fireproof-docs` (result symlink to the rendered Markdown).
{
  inputs,
  lib,
  ...
}: {
  perSystem = {pkgs, ...}: let
    # Reuse a fully-evaluated host so option declarations from every module
    # (base, desktop, homelab, theme, ...) are aggregated, not just one file.
    eval = inputs.self.nixosConfigurations.desktop;

    # Flake source path in the store, e.g. /nix/store/xxxx-source — strip it so
    # declaration links become repo-relative and point at GitHub.
    repoUrl = "https://github.com/nickolaj-jepsen/nixos/blob/main";
    storePrefix = toString inputs.self;

    optionsDoc = pkgs.nixosOptionsDoc {
      # Document the `fireproof` subtree, minus `fireproof.home-manager` — that
      # is a passthrough wrapper exposing the entire upstream home-manager/niri
      # option set, not our own options.
      options.fireproof = removeAttrs eval.options.fireproof ["home-manager"];
      warningsAreErrors = false;
      transformOptions = opt:
        opt
        // {
          declarations =
            map (
              decl: let
                rel = lib.removePrefix "/" (lib.removePrefix storePrefix (toString decl));
              in {
                name = rel;
                url = "${repoUrl}/${rel}";
              }
            )
            opt.declarations;
        };
    };
  in {
    packages.fireproof-docs = optionsDoc.optionsCommonMark;
  };
}
