# Aspect selection layer (flake-parts level). Declares the bundle graph and the
# reverse-membership tags that the host builder resolves into per-host module
# sets via lib/aspects.nix. Inert until the host builder consumes them; the
# graph data and per-leaf tags land with the cutover.
{lib, ...}: {
  options.flake.bundles = lib.mkOption {
    type = lib.types.lazyAttrsOf (lib.types.submodule {
      options = {
        includes = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          description = "Other bundles this bundle pulls in (the DAG edges).";
        };
        facts = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = {};
          description = "fireproof.* facts this bundle sets on hosts that select it.";
        };
      };
    });
    default = {};
    description = "Aspect bundles: includes-only nodes in the selection DAG (leaves attach via aspectTags).";
  };

  options.flake.aspectTags = lib.mkOption {
    type = lib.types.lazyAttrsOf (lib.types.listOf lib.types.str);
    default = {};
    description = "Reverse membership: aspectTags.<leaf> lists the bundles the leaf belongs to.";
  };
}
