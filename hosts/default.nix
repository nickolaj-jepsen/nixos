{
  inputs,
  withSystem,
  config,
  ...
}: let
  inherit (inputs.nixpkgs) lib;
  fpLib = import ../lib {inherit lib;};
  aspectsLib = import ../lib/aspects.nix {inherit lib;};
  mkHome = import ../lib/mkHome.nix {
    inherit inputs lib fpLib aspectsLib;
    inherit (config) flake;
  };

  # Host classes the builder routes; a card's `class` (default "nixos") picks the
  # instantiator and the flake output it lands in. Adding "darwin" later is: a
  # value here, a buildDarwin, a darwinConfigurations emit, and the
  # flake.modules.darwin name union in wrapAspect (so darwin leaves get tagged).
  validClasses = ["nixos" "home"];

  # Selection graph + reverse-tags, each guarded once at first use: a cycle in the
  # bundle DAG and a duplicate leaf name (flat-namespace collision) are otherwise
  # silent. `seq` forces the guard before handing back the value it protects.
  bundles = builtins.seq (aspectsLib.assertAcyclic config.flake.bundles) config.flake.bundles;
  aspectTags = builtins.seq (aspectsLib.assertUniqueNames config.flake.aspectTags) config.flake.aspectTags;

  # Collect a host directory into module buckets. Every top-level `.nix` file
  # (skipping `_`-prefixed helpers) must be a CARD: an attrset over
  # {class, aspects, shared, nixos, homeManager}, the same shape as host.nix. A
  # bare NixOS module — a function, or an attrset carrying any other key — is
  # rejected loudly; its body belongs in the `nixos` bucket. Buckets are
  # concatenated across every card in the dir, so any file may contribute
  # aspects/facts/HM, not just host.nix. `class` is the one scalar (routes the
  # whole host). Host dirs are flat, so a shallow readDir suffices.
  collect = dir: let
    cardKeys = ["class" "aspects" "shared" "nixos" "homeManager"];
    names =
      lib.filter
      (n: lib.hasSuffix ".nix" n && !(lib.hasPrefix "_" n))
      (lib.attrNames (lib.filterAttrs (_: t: t == "regular") (builtins.readDir dir)));
    load = n: let
      path = dir + "/${n}";
      card = import path;
      stray = lib.subtractLists cardKeys (lib.attrNames card);
    in
      if !(builtins.isAttrs card)
      then throw "${toString path}: host files must be cards (an attrset over {${lib.concatStringsSep ", " cardKeys}}), not a module — wrap the body in a `nixos = { … };` bucket"
      else if stray != []
      then throw "${toString path}: unknown host-card key(s) [${lib.concatStringsSep " " stray}] — allowed {${lib.concatStringsSep ", " cardKeys}}; put NixOS config under `nixos`"
      else card;
    cards = map load names;
    # `class` routes the whole host (scalar, read pre-eval — the builder must pick
    # nixosSystem vs homeManagerConfiguration before the module system runs). At
    # most one card may set it; default "nixos". Validated so a typo throws loudly
    # instead of silently mis-routing into a class with no builder.
    class = let
      vals = lib.unique (map (c: c.class) (lib.filter (c: c ? class) cards));
    in
      if vals == []
      then "nixos"
      else if lib.length vals > 1
      then throw "${toString dir}: conflicting `class` values across cards: ${lib.concatStringsSep ", " vals}"
      else if !(lib.elem (lib.head vals) validClasses)
      then throw "${toString dir}: unknown host class \"${lib.head vals}\" — known: ${lib.concatStringsSep ", " validClasses}"
      else lib.head vals;
  in {
    inherit class;
    aspects = lib.concatMap (c: c.aspects or []) cards;
    shared = lib.catAttrs "shared" cards;
    nixos = lib.catAttrs "nixos" cards;
    homeManager = lib.catAttrs "homeManager" cards;
  };

  # Assemble a NixOS system from resolved buckets. `shared` modules set fireproof.*
  # in BOTH evals (the no-bridge fact flow); the home-manager user is read from the
  # resulting config.fireproof.username. Aspects select the dendritic leaves by
  # membership; NIXOS-only host settings live as plain modules in the host dir.
  mkNixos = {
    aspects ? [],
    shared ? [],
    nixosModules ? [],
    homeManagerModules ? [],
    system ? "x86_64-linux",
  }:
    withSystem system (
      {system, ...}: let
        selectedNames = aspectsLib.selectedLeaves bundles aspectTags (["base"] ++ aspects);
        nixosLeaves = aspectsLib.pick selectedNames config.flake.modules.nixos;
        homeLeaves = aspectsLib.pick selectedNames config.flake.modules.homeManager;
      in
        inputs.nixpkgs.lib.nixosSystem {
          specialArgs = {inherit inputs fpLib;};
          modules =
            [
              {nixpkgs.hostPlatform = system;}
              inputs.disko.nixosModules.disko
              inputs.nixos-generators.nixosModules.all-formats
              inputs.home-manager.nixosModules.home-manager
              inputs.agenix.nixosModules.default
              inputs.agenix-rekey.nixosModules.default
              inputs.nix-index-database.nixosModules.nix-index
              inputs.nixos-facter-modules.nixosModules.facter
              inputs.dank-material-shell.nixosModules.dank-material-shell
              inputs.niri.nixosModules.niri
              inputs.nixos-wsl.nixosModules.default
              inputs.self.nixosModules.overlays
              ({config, ...}: {
                # Home-manager wiring: define the user (so the shared modules have
                # someone to apply to), share system pkgs/state, and pin both
                # stateVersions (mkDefault so a host — e.g. desktop-wsl — can bump
                # system.stateVersion).
                home-manager = {
                  useUserPackages = true;
                  useGlobalPkgs = true;
                  extraSpecialArgs = {inherit inputs fpLib;};
                  sharedModules =
                    homeLeaves
                    ++ homeManagerModules
                    ++ shared
                    ++ [{home.stateVersion = lib.mkDefault "24.11";}];
                  users.${config.fireproof.username} = {};
                };
                system.stateVersion = lib.mkDefault "24.11";
              })
            ]
            ++ shared
            ++ nixosLeaves
            ++ nixosModules;
        }
    );

  # Build a host from its directory: collect its card(s) + sibling nixos modules.
  buildHost = dir: let
    c = collect dir;
  in
    mkNixos {
      inherit (c) aspects shared;
      nixosModules = c.nixos;
      homeManagerModules = c.homeManager;
    };

  # A home-class host (class = "home"): no NixOS eval, just the standalone
  # home-manager leaves its aspects select. The card's `shared` (facts) and
  # `homeManager` (tweaks) buckets feed the eval as modules; a `nixos` bucket has
  # nowhere to apply, so it's a loud error.
  buildHome = dir: let
    c = collect dir;
  in
    assert lib.assertMsg (c.nixos == []) "${toString dir}: a home-class host has no NixOS eval — move `nixos` config to `homeManager`/`shared`";
      mkHome {
        inherit (c) aspects;
        extraModules = c.shared ++ c.homeManager;
      };

  # A host is any hosts/<name>/ directory containing a host.nix card. _templates/
  # (no card) is excluded for free — the fleet is discovered, not enumerated.
  hostDir = name: ./. + "/${name}";
  isHost = name: type: type == "directory" && builtins.pathExists (hostDir name + "/host.nix");
  discovered = lib.attrNames (lib.filterAttrs isHost (builtins.readDir ./.));

  # Route each discovered host by its card's `class` (default "nixos").
  hostClassOf = name: (collect (hostDir name)).class;
  nixosHosts = lib.filter (n: hostClassOf n == "nixos") discovered;
  homeHosts = lib.filter (n: hostClassOf n == "home") discovered;
in {
  # The installable fleet (nixos-class hosts), exposed for installer/ to fan out
  # bootstrap-<host> ISOs over. Home-class hosts have no install ISO, so they are
  # excluded here.
  config.flake.hostNames = nixosHosts;

  # Resolved selection per host (every class), for inspection via `just aspects <host>`.
  config.flake.aspects = lib.genAttrs discovered (name: let
    asp = (collect (hostDir name)).aspects;
  in {
    aspects = asp;
    closure = aspectsLib.closure bundles (["base"] ++ asp);
    leaves = aspectsLib.selectedLeaves bundles aspectTags (["base"] ++ asp);
  });

  config.flake.nixosConfigurations =
    lib.genAttrs nixosHosts (name: buildHost (hostDir name));

  # Standalone home-manager hosts (class = "home"): no NixOS eval. dev-ao is the
  # work dev server, also built in `just check` (home-check.nix) as the
  # standalone-HM portability guard.
  config.flake.homeConfigurations =
    lib.genAttrs homeHosts (name: buildHome (hostDir name));
}
