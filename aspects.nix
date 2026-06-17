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

  # The bundle DAG. `includes` are edges to other bundles; `facts` are the
  # fireproof.* values a selecting host gets (injected into both the nixos and
  # home-manager evals — no osConfig bridge). Leaves attach by tagging a bundle
  # name in their flake.aspectTags. Opt-in features (chromium, bambu, …) are
  # bundles a host adds explicitly; the matching option defaults to off.
  config.flake.bundles = {
    # window manager + shell (membership target for niri/* and dms)
    windowManager.includes = [];

    # the three top-level capabilities
    desktop = {
      includes = ["windowManager"];
      facts = {desktop.enable = true;};
    };
    dev.facts = {dev.enable = true;};
    work.facts = {work.enable = true;};
    homelab.facts = {homelab.enable = true;};

    # hardware-shaped bundles
    physical.includes = []; # btrfs-scrub/smartd/thermald/journald/zram tag here
    laptop = {
      includes = ["physical"];
      facts = {hardware.laptop = true;}; # battery/wifi/dimmableBacklight follow
    };
    nvidia.facts = {hardware.nvidia.enable = true;};
    wsl.facts = {wsl.enable = true;};

    # intersections
    gui-dev.includes = ["desktop" "dev"]; # vscode/zed/sublime editors tag here
    gui-work.includes = ["desktop" "work"]; # slack/ferdium tag here
    workstation.includes = ["gui-dev" "gui-work"];

    # opt-in feature bundles (the matching fireproof option defaults to off)
    chromium.facts = {desktop.chromium.enable = true;};
    bambu.facts = {desktop.bambu-studio.enable = true;};
    google-chrome.facts = {desktop.google-chrome.enable = true;};
    claude-work.facts = {claude-code.work.enable = true;};
    intellij.facts = {dev.intellij.enable = true;};
    clickhouse.facts = {dev.clickhouse.enable = true;};

    # nixos-only opt-in leaves (no shared fact; their parametric options stay
    # host-set on the nixos side); membership target only
    snapcast.includes = [];
    oxcb-media.includes = [];

    # homelab opt-in services, off on every host today (membership targets)
    attic.includes = [];
    beszel.includes = [];
    kavita.includes = [];
    shelfmark.includes = [];
  };
}
