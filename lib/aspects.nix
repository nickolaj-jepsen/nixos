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
}
