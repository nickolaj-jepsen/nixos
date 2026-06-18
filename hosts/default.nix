{
  inputs,
  withSystem,
  config,
  ...
}: let
  inherit (inputs.nixpkgs) lib;
  fpLib = import ../lib {inherit lib;};
  mkHome = import ../lib/mkHome.nix {
    inherit inputs lib fpLib;
    inherit (config) flake;
  };

  validClasses = ["nixos" "home"];

  collect = dir: let
    cardKeys = ["class" "shared" "nixos" "homeManager"];
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
    # class is read pre-eval (before the module system runs), so it routes the whole host.
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
    shared = lib.catAttrs "shared" cards;
    nixos = lib.catAttrs "nixos" cards;
    homeManager = lib.catAttrs "homeManager" cards;
  };

  # `shared` sets fireproof.* in BOTH evals (the no-bridge fact flow); HM user read from resulting config.fireproof.username.
  mkNixos = {
    shared ? [],
    nixosModules ? [],
    homeManagerModules ? [],
    system ? "x86_64-linux",
  }:
    withSystem system (
      {system, ...}: let
        nixosLeaves = builtins.attrValues config.flake.modules.nixos;
        homeLeaves = builtins.attrValues config.flake.modules.homeManager;
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
                # mkDefault on both stateVersions so a host (e.g. desktop-wsl) can bump system.stateVersion.
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

  buildHost = dir: let
    c = collect dir;
  in
    mkNixos {
      inherit (c) shared;
      nixosModules = c.nixos;
      homeManagerModules = c.homeManager;
    };

  # home-class host: no NixOS eval, so a `nixos` bucket has nowhere to apply (loud error).
  buildHome = dir: let
    c = collect dir;
  in
    assert lib.assertMsg (c.nixos == []) "${toString dir}: a home-class host has no NixOS eval — move `nixos` config to `homeManager`/`shared`";
      mkHome {
        extraModules = c.shared ++ c.homeManager;
      };

  # A host is any hosts/<name>/ dir containing a host.nix card; _templates/ (no card) excluded for free.
  hostDir = name: ./. + "/${name}";
  isHost = name: type: type == "directory" && builtins.pathExists (hostDir name + "/host.nix");
  discovered = lib.attrNames (lib.filterAttrs isHost (builtins.readDir ./.));

  hostClassOf = name: (collect (hostDir name)).class;
  nixosHosts = lib.filter (n: hostClassOf n == "nixos") discovered;
  homeHosts = lib.filter (n: hostClassOf n == "home") discovered;
in {
  # nixos-class only: home-class hosts have no install ISO for installer/ to fan out over.
  config.flake.hostNames = nixosHosts;

  config.flake.nixosConfigurations =
    lib.genAttrs nixosHosts (name: buildHost (hostDir name));

  config.flake.homeConfigurations =
    lib.genAttrs homeHosts (name: buildHome (hostDir name));
}
