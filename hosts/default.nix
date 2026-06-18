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

  # Resolve a host's aspects into the fireproof.* fact set its bundles provide
  # (host-specific facts win), then inject that set into BOTH the nixos and the
  # home-manager evals — the no-bridge fact flow. Leaves are still imported
  # wholesale and self-gate via mkIf during the cutover; membership selection
  # replaces that in the final step.
  mkSystem = {
    dir,
    aspects ? [],
    facts ? {},
    modules ? [],
    # Host-specific home-manager modules, merged into the user's HM eval next to
    # the selected homeLeaves. Replaces the fireproof.home-manager alias for the
    # few per-host HM tweaks (runelite, ssh overrides, firefox homepage).
    homeModules ? [],
    system ? "x86_64-linux",
  }:
    withSystem system (
      {system, ...}: let
        resolvedFacts = aspectsLib.facts config.flake.bundles aspects facts;
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
              {fireproof = resolvedFacts;}
              {
                home-manager.sharedModules = homeLeaves ++ homeModules ++ [{fireproof = resolvedFacts;}];
                home-manager.extraSpecialArgs = {inherit inputs fpLib;};
              }
            ]
            ++ nixosLeaves
            # The host's own directory (its default.nix and sibling files).
            # `_`-prefixed helper files are skipped (see import-tree).
            ++ [(inputs.import-tree dir)]
            ++ modules;
        }
    );

  # Each host names the aspects it selects (resolved transitively into the
  # fireproof.* facts above) plus host-specific facts. NIXOS-only host settings
  # (steam, snapcast captures, binfmt, …) live in the host's own directory.
  targets = {
    desktop = {
      dir = ./desktop;
      aspects = ["workstation" "physical" "nvidia" "chromium" "bambu" "intellij" "clickhouse" "claude-work" "snapcast"];
      facts = {
        hostname = "desktop";
        username = "nickolaj";
        hardware.gpuPciId = "10de:2c05";
        monitors = import ./desktop/_monitors.nix;
      };
      homeModules = [./desktop/_home.nix];
    };
    laptop = {
      dir = ./laptop;
      aspects = ["workstation" "laptop" "chromium" "intellij" "clickhouse"];
      facts = {
        hostname = "laptop";
        username = "nickolaj";
        monitors = import ./laptop/_monitors.nix;
      };
      homeModules = [./laptop/_home.nix];
    };
    work = {
      dir = ./work;
      aspects = ["workstation" "physical" "nvidia" "chromium" "intellij" "clickhouse" "claude-work"];
      facts = {
        hostname = "work";
        username = "nickolaj";
        monitors = import ./work/_monitors.nix;
      };
      homeModules = [./work/_home.nix];
    };
    homelab = {
      dir = ./homelab;
      aspects = ["dev" "homelab" "physical" "clickhouse"];
      facts = {
        hostname = "homelab";
        username = "nickolaj";
      };
    };
    minilab = {
      dir = ./minilab;
      aspects = ["gui-dev" "physical" "snapcast" "oxcb-media"];
      facts = {
        hostname = "minilab";
        username = "nickolaj";
        monitors = import ./minilab/_monitors.nix;
      };
    };
    desktop-wsl = {
      dir = ./desktop-wsl;
      aspects = ["dev" "work" "wsl" "clickhouse"];
      facts = {
        hostname = "desktop-wsl";
        username = "nickolaj";
      };
      homeModules = [./desktop-wsl/_home.nix];
    };
  };

  # Facts for the bootstrap installer image. Passed through the facts mechanism
  # (not set nixos-side in hosts/bootstrap/) so they reach the home-manager eval
  # too — hm-secrets reads fireproof.hostname there.
  bootstrapFacts = {
    hostname = "bootstrap";
    username = "nickolaj";
  };

  mkBootstrap = name:
    mkSystem {
      dir = ./bootstrap;
      facts = bootstrapFacts;
      modules = [
        ./bootstrap/_bake.nix
        {fireproof.bootstrap.targetHost = name;}
      ];
    };
in {
  # Resolved selection per host, for inspection via `just aspects <host>`.
  config.flake.aspects =
    lib.mapAttrs (_: host: {
      inherit (host) aspects;
      closure = aspectsLib.closure config.flake.bundles (["base"] ++ host.aspects);
      leaves = aspectsLib.selectedLeaves config.flake.bundles config.flake.aspectTags (["base"] ++ host.aspects);
    })
    targets;

  config.flake.nixosConfigurations =
    (lib.mapAttrs (_: mkSystem) targets)
    // {
      bootstrap = mkSystem {
        dir = ./bootstrap;
        facts = bootstrapFacts;
      };
    }
    // (lib.mapAttrs' (name: _: lib.nameValuePair "bootstrap-${name}" (mkBootstrap name)) targets);
}
