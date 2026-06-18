# Aspect selection layer (flake-parts level). Declares the bundle graph that the
# host builder resolves into per-host module sets via lib/aspects.nix. Bundles are
# pure adjacency: an aspect is a membership tag carrying no data. A "fact" is just
# a fireproof.* option set in a host's `shared` card or an aspect-tagged leaf, and
# the module system merges those with real precedence — no parallel merge engine.
{lib, ...}: {
  options.flake.bundles = lib.mkOption {
    type = lib.types.lazyAttrsOf (lib.types.listOf lib.types.str);
    default = {};
    description = "Aspect bundles: composing nodes in the selection DAG (name -> the bundles it pulls in). Pass-through aspects need no entry (resolved via `or []`).";
  };

  options.flake.aspectTags = lib.mkOption {
    type = lib.types.lazyAttrsOf (lib.types.listOf lib.types.str);
    default = {};
    description = "Reverse membership: aspectTags.<leaf> lists the bundles the leaf belongs to.";
  };

  # The bundle DAG: each entry lists the bundles it pulls in (the edges). Leaves
  # attach by tagging a bundle name in their flake.aspectTags (stamped from their
  # folder by wrapAspect in flake.nix). Only composing nodes appear here; every
  # other aspect (nix, dev, work, desktop, nvidia, chromium, snapcast, …) is a pass-through
  # name the closure carries via `or []`, selected directly by a host or pulled in
  # as an edge below. `base` MUST stay — the builder prepends it to every host and
  # the always-on aspect folders ride in on its edges.
  config.flake.bundles = {
    base = ["nix" "system" "cli" "secrets" "scripts" "fireproof-options" "docker"];

    laptop = ["physical"];

    gui-dev = ["desktop" "dev"];
    gui-work = ["desktop" "work"];
    workstation = ["gui-dev" "gui-work"];
  };

  # No central aspectTags: every leaf is folder-tagged by wrapAspect (flake.nix),
  # or carries its own flake.aspectTags override. The option above accumulates
  # those per-file stamps.
}
