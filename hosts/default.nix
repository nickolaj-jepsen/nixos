{
  inputs,
  config,
  ...
}: let
  inherit (inputs.nixpkgs) lib;

  validClasses = ["nixos" "home" "darwin"];
  cardKeys = ["class" "shared" "nixos" "homeManager" "darwin"];

  collect = dir: let
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
    darwin = lib.catAttrs "darwin" cards;
  };

  homeLeaves = builtins.attrValues config.flake.modules.homeManager;

  # niri-flake's nixos module wires up its own HM half; darwin + standalone HM import it by hand so the inert niri leaves type-check.
  niriHome = [
    inputs.niri.homeModules.niri
    ({pkgs, ...}: {programs.niri.package = lib.mkDefault pkgs.niri-unstable;})
  ];

  # `shared` sets fireproof.* in BOTH evals (the no-bridge fact flow); HM user read from resulting config.fireproof.username.
  embeddedHome = modules: {config, ...}: {
    home-manager = {
      useUserPackages = true;
      useGlobalPkgs = true;
      sharedModules = homeLeaves ++ modules;
      users.${config.fireproof.username} = {};
    };
  };

  mkNixos = {
    shared ? [],
    nixosModules ? [],
    homeManagerModules ? [],
    system ? "x86_64-linux",
  }:
    inputs.nixpkgs.lib.nixosSystem {
      modules =
        [
          {nixpkgs.hostPlatform = system;}
          inputs.home-manager.nixosModules.home-manager
          inputs.self.nixosModules.overlays
          (embeddedHome (homeManagerModules ++ shared))
        ]
        ++ shared
        ++ builtins.attrValues config.flake.modules.nixos
        ++ nixosModules;
    };

  # darwinSystem takes no `system` arg — platform is set via nixpkgs.hostPlatform.
  mkDarwin = {
    shared ? [],
    homeManagerModules ? [],
    darwinModules ? [],
    system ? "aarch64-darwin",
  }:
    inputs.nix-darwin.lib.darwinSystem {
      modules =
        [
          {nixpkgs.hostPlatform = system;}
          inputs.home-manager.darwinModules.home-manager
          inputs.self.darwinModules.overlays
          (embeddedHome (homeManagerModules ++ shared ++ niriHome))
          ({config, ...}: let
            inherit (config.fireproof) username hostname;
          in {
            # primaryUser + the user's home are required by homebrew + embedded HM activation.
            users.users.${username}.home = "/Users/${username}";
            system.primaryUser = username;
            # nix-darwin defaults hostName to null; agenix-rekey's target-name needs it set.
            networking.hostName = lib.mkDefault hostname;
            networking.computerName = lib.mkDefault hostname;
          })
        ]
        ++ shared
        ++ builtins.attrValues config.flake.modules.darwin
        ++ darwinModules;
    };

  # Standalone home-manager (osConfig = null): builds its own pkgs + identity.
  mkHome = {
    modules ? [],
    system ? "x86_64-linux",
  }:
    inputs.home-manager.lib.homeManagerConfiguration {
      pkgs = import inputs.nixpkgs {
        inherit system;
        config.allowUnfree = true;
        overlays = config.flake.lib.overlays;
      };
      modules =
        homeLeaves
        ++ niriHome
        ++ [
          ({config, ...}: {
            home.username = lib.mkDefault config.fireproof.username;
            home.homeDirectory = lib.mkDefault "/home/${config.fireproof.username}";
          })
        ]
        ++ modules;
    };

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
        modules = c.shared ++ c.homeManager;
      };

  # darwin-class host: nix-darwin eval only, so a `nixos` bucket has nowhere to apply (loud error).
  buildDarwin = dir: let
    c = collect dir;
  in
    assert lib.assertMsg (c.nixos == []) "${toString dir}: a darwin-class host has no NixOS eval — move `nixos` config to `darwin`/`homeManager`/`shared`";
      mkDarwin {
        inherit (c) shared;
        homeManagerModules = c.homeManager;
        darwinModules = c.darwin;
      };

  # A host is any hosts/<name>/ dir containing a host.nix card; _templates/ (no card) excluded for free.
  hostDir = name: ./. + "/${name}";
  isHost = name: type: type == "directory" && builtins.pathExists (hostDir name + "/host.nix");
  discovered = lib.attrNames (lib.filterAttrs isHost (builtins.readDir ./.));

  hostClassOf = name: (collect (hostDir name)).class;
  nixosHosts = lib.filter (n: hostClassOf n == "nixos") discovered;
  homeHosts = lib.filter (n: hostClassOf n == "home") discovered;
  darwinHosts = lib.filter (n: hostClassOf n == "darwin") discovered;
in {
  # nixos-class only: home/darwin-class hosts have no install ISO for installer/ to fan out over.
  config.flake.hostNames = nixosHosts;
  # home-check.nix validates the disko templates against the same card shape.
  config.flake.hostCardKeys = cardKeys;

  config.flake.nixosConfigurations =
    lib.genAttrs nixosHosts (name: buildHost (hostDir name));

  config.flake.homeConfigurations =
    lib.genAttrs homeHosts (name: buildHome (hostDir name));

  config.flake.darwinConfigurations =
    lib.genAttrs darwinHosts (name: buildDarwin (hostDir name));
}
