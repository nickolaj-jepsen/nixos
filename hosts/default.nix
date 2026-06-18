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

  # Collect a host directory into module buckets. Each top-level `.nix` file
  # (skipping `_`-prefixed helpers) is imported and classified: a file exposing
  # any of aspects/shared/nixos/homeManager is a host "card"; anything else is a
  # plain nixos module imported by value. Host dirs are flat, so a shallow readDir
  # matches the import-tree this replaces.
  collect = dir: let
    names =
      lib.filter
      (n: lib.hasSuffix ".nix" n && !(lib.hasPrefix "_" n))
      (lib.attrNames (lib.filterAttrs (_: t: t == "regular") (builtins.readDir dir)));
    files = map (n: import (dir + "/${n}")) names;
    isCard = f: builtins.isAttrs f && (f ? aspects || f ? shared || f ? nixos || f ? homeManager);
    cards = lib.filter isCard files;
    plain = lib.filter (f: !(isCard f)) files;
  in {
    aspects = lib.concatMap (c: c.aspects or []) cards;
    shared = map (c: c.shared) (lib.filter (c: c ? shared) cards);
    nixos = (map (c: c.nixos) (lib.filter (c: c ? nixos) cards)) ++ plain;
    homeManager = map (c: c.homeManager) (lib.filter (c: c ? homeManager) cards);
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

  # name -> host directory. (Reduced from the old targets registry; replaced by
  # marker-file discovery in the next step.)
  targets = {
    desktop = ./desktop;
    laptop = ./laptop;
    work = ./work;
    homelab = ./homelab;
    minilab = ./minilab;
    desktop-wsl = ./desktop-wsl;
  };
in {
  # Resolved selection per host, for inspection via `just aspects <host>`.
  config.flake.aspects =
    lib.mapAttrs (_: dir: let
      asp = (collect dir).aspects;
    in {
      aspects = asp;
      closure = aspectsLib.closure config.flake.bundles (["base"] ++ asp);
      leaves = aspectsLib.selectedLeaves config.flake.bundles config.flake.aspectTags (["base"] ++ asp);
    })
    targets;

  config.flake.nixosConfigurations =
    (lib.mapAttrs (_: buildHost) targets)
    // {bootstrap = buildBootstrap null;}
    // (lib.mapAttrs' (name: _: lib.nameValuePair "bootstrap-${name}" (buildBootstrap name)) targets);
}
