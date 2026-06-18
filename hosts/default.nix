{
  inputs,
  withSystem,
  config,
  ...
}: let
  inherit (inputs.nixpkgs) lib;
  fpLib = import ../lib {inherit lib;};
  aspectsLib = import ../lib/aspects.nix {inherit lib;};

  # Pick the dendritic leaves selected by a host (membership: a leaf is selected
  # when one of its aspectTags is in the resolved bundle closure), restricted to
  # the names actually present in the given class.
  pick = selectedNames: modset:
    builtins.attrValues (lib.getAttrs (builtins.filter (n: modset ? ${n}) selectedNames) modset);

  # Collect a host directory into module buckets. Every top-level `.nix` file
  # (skipping `_`-prefixed helpers) must be a CARD: an attrset over
  # {aspects, shared, nixos, homeManager}, the same shape as host.nix. A bare
  # NixOS module — a function, or an attrset carrying any other key — is rejected
  # loudly; its body belongs in the `nixos` bucket. Buckets are concatenated
  # across every card in the dir, so any file may contribute aspects/facts/HM,
  # not just host.nix. Host dirs are flat, so a shallow readDir suffices.
  collect = dir: let
    cardKeys = ["aspects" "shared" "nixos" "homeManager"];
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
  in {
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
        selectedNames = aspectsLib.selectedLeaves config.flake.bundles config.flake.aspectTags (["base"] ++ aspects);
        nixosLeaves = pick selectedNames config.flake.modules.nixos;
        homeLeaves = pick selectedNames config.flake.modules.homeManager;
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
                # Home-manager wiring that used to live in the fireproof.home-manager
                # alias module: define the user (so the shared modules have someone
                # to apply to), share system pkgs/state, and pin both stateVersions
                # (mkDefault so a host — e.g. desktop-wsl — can bump system.stateVersion).
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

  # The bootstrap installer image. Its facts are passed as a `shared` module so they
  # reach the home-manager eval too (hm-secrets reads fireproof.hostname there).
  # name == null is the generic ISO; a host name adds the source-baking _bake leaf
  # plus the targetHost string it stamps into the image.
  bootstrapFacts = {
    hostname = "bootstrap";
    username = "nickolaj";
  };
  buildBootstrap = name:
    mkNixos {
      shared = [{fireproof = bootstrapFacts;}];
      nixosModules =
        (collect ./bootstrap).nixos
        ++ lib.optionals (name != null) [
          ./bootstrap/_bake.nix
          {fireproof.bootstrap.targetHost = name;}
        ];
    };

  # A host is any hosts/<name>/ directory containing a host.nix card. bootstrap/
  # (no card) and _templates/ are excluded for free — the fleet is discovered,
  # not enumerated.
  hostDir = name: ./. + "/${name}";
  isHost = name: type: type == "directory" && builtins.pathExists (hostDir name + "/host.nix");
  hostNames = lib.attrNames (lib.filterAttrs isHost (builtins.readDir ./.));
in {
  # Resolved selection per host, for inspection via `just aspects <host>`.
  config.flake.aspects = lib.genAttrs hostNames (name: let
    asp = (collect (hostDir name)).aspects;
  in {
    aspects = asp;
    closure = aspectsLib.closure config.flake.bundles (["base"] ++ asp);
    leaves = aspectsLib.selectedLeaves config.flake.bundles config.flake.aspectTags (["base"] ++ asp);
  });

  config.flake.nixosConfigurations =
    lib.genAttrs hostNames (name: buildHost (hostDir name))
    // {bootstrap = buildBootstrap null;}
    // lib.listToAttrs (map (n: lib.nameValuePair "bootstrap-${n}" (buildBootstrap n)) hostNames);
}
