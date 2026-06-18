# Pure aspect resolver: a small transitive-closure over the bundle DAG plus leaf
# selection by reverse-tags. Deliberately shaped like den's `includes` model
# (https://github.com/denful/den) so it can be swapped for `den` later without
# touching callers. Bundles are pure adjacency (name -> [names]); a "fact" is just
# a fireproof.* option set in a module.
{lib}: rec {
  # Transitive closure of `selected` aspect names over the bundles' edges.
  # `selected` and every edge entry name a *bundle*; leaves attach via
  # reverse-tags (see selectedLeaves), never via edges. A name with no bundle
  # entry is a pass-through (no further edges, via `or []`). Cycle-safe:
  # already-seen nodes are skipped.
  closure = bundles: selected: let
    step = seen: frontier:
      if frontier == []
      then seen
      else let
        n = lib.head frontier;
        rest = lib.tail frontier;
      in
        if lib.elem n seen
        then step seen rest
        else step (seen ++ [n]) (rest ++ (bundles.${n} or []));
  in
    step [] selected;

  # Leaf names selected by a host: every leaf whose tag list intersects the
  # host's resolved bundle closure.
  selectedLeaves = bundles: aspectTags: hostAspects: let
    sel = closure bundles hostAspects;
  in
    lib.filter
    (name: lib.any (t: lib.elem t sel) aspectTags.${name})
    (lib.attrNames aspectTags);

  # Restrict selected leaf names to those present in a module class, returning
  # the module values for that class. Shared by the embedded (hosts/default.nix)
  # and standalone (lib/mkHome.nix) builders so both pick leaves identically.
  pick = selectedNames: modset:
    builtins.attrValues
    (lib.getAttrs (builtins.filter (n: modset ? ${n}) selectedNames) modset);

  # Guard: throw if the bundle graph has a cycle. `closure` skips already-seen
  # nodes, so an accidental edge forming a loop is silent without this. DFS over
  # the current path (not the global seen set), so a diamond — e.g. gui-dev and
  # gui-work both pulling `desktop` — is not mistaken for a cycle. Returns true.
  assertAcyclic = bundles: let
    visit = path: node:
      if lib.elem node path
      then throw "fireproof: bundle DAG has a cycle: ${lib.concatStringsSep " -> " (path ++ [node])}"
      else lib.all (visit (path ++ [node])) (bundles.${node} or []);
  in
    lib.all (visit []) (lib.attrNames bundles);

  # Guard: throw on a flat-namespace collision — a module name stamped by more
  # than one file. wrapAspect stamps exactly one tag per name per file, so a tag
  # list longer than one means the same flake.modules.<class>.<name> was declared
  # twice (the silent merge that forced renames like `postgres-cli`). Returns true.
  assertUniqueNames = aspectTags: let
    dupes = lib.filter (n: lib.length aspectTags.${n} > 1) (lib.attrNames aspectTags);
  in
    if dupes == []
    then true
    else
      throw "fireproof: module name(s) declared in more than one file: ${
        lib.concatStringsSep ", " (map (n: "${n} (${lib.concatStringsSep "+" aspectTags.${n}})") dupes)
      } — flake.modules.<class> is one flat namespace; names must be globally unique";
}
