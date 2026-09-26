{
  description = "NixOS configuration";

  outputs = {flake-parts, ...} @ inputs:
    flake-parts.lib.mkFlake {inherit inputs;} {
      imports = [
        inputs.flake-parts.flakeModules.modules
        inputs.agenix-rekey.flakeModule
        ./formatter.nix
        ./devshell.nix
        ./docs.nix
        ./home-check.nix
        ./lib/flake-module.nix
        ./hosts
        ./installer
        ./overlays
        # Every file under ./modules is a self-declaring dendritic module that sets
        # flake.modules.{nixos,homeManager}.<name>. import-tree auto-collects them
        # all; each leaf self-gates with lib.mkIf config.fireproof.<feature>.enable.
        (inputs.import-tree ./modules)
      ];
      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];
    };

  inputs = {
    # nixos-* only advances once Hydra has built + tested it; release-* is the raw dev branch.
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";

    nix-index-database.url = "github:nix-community/nix-index-database";
    nix-index-database.inputs.nixpkgs.follows = "nixpkgs";

    home-manager.url = "github:nix-community/home-manager/release-26.05";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    # nix-darwin-26.05 must match the nixpkgs 26.05 release (enableNixpkgsReleaseCheck).
    nix-darwin.url = "github:nix-darwin/nix-darwin/nix-darwin-26.05";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";

    # nix-homebrew manages the brew install + taps (pinned as inputs since
    # mutableTaps = false); casks live in nix-darwin's own homebrew.* module.
    nix-homebrew.url = "github:zhaofengli/nix-homebrew";
    homebrew-core = {
      url = "github:homebrew/homebrew-core";
      flake = false;
    };
    homebrew-cask = {
      url = "github:homebrew/homebrew-cask";
      flake = false;
    };

    # Trampolines so nix-built .app bundles (vscode) show up in Spotlight/Dock.
    mac-app-util.url = "github:hraban/mac-app-util";
    mac-app-util.inputs.nixpkgs.follows = "nixpkgs";
    mac-app-util.inputs.treefmt-nix.follows = "treefmt-nix";
    mac-app-util.inputs.cl-nix-lite.inputs.nixpkgs.follows = "nixpkgs";
    mac-app-util.inputs.cl-nix-lite.inputs.flake-parts.follows = "flake-parts";
    mac-app-util.inputs.cl-nix-lite.inputs.treefmt-nix.follows = "treefmt-nix";

    firefox-addons.url = "gitlab:rycee/nur-expressions?dir=pkgs/firefox-addons";
    firefox-addons.inputs.nixpkgs.follows = "nixpkgs";

    nixos-wsl.url = "github:nix-community/NixOS-WSL/main";
    nixos-wsl.inputs.nixpkgs.follows = "nixpkgs";

    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";

    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";

    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";

    # Recursively imports every `.nix` file under a directory (skipping any
    # `_`-prefixed path), so module/host/overlay trees are auto-imported
    # instead of maintained as hand-written `imports = [ … ]` lists.
    import-tree.url = "github:vic/import-tree";

    # Follows ours: the closure override in modules/programs/pi.nix already misses
    # pi.cachix.org, so a private nixpkgs only bought duplicate nodejs/icu/glibc.
    pi.url = "github:lukasl-dev/pi.nix";
    pi.inputs.nixpkgs.follows = "nixpkgs";
    pi.inputs.flake-parts.follows = "flake-parts";
    # pi only reads its *-x86_64-darwin inputs on that system, which no host is.
    pi.inputs.nixpkgs-x86_64-darwin.follows = "nixpkgs";
    pi.inputs.bun2nix-x86_64-darwin.follows = "pi/bun2nix";
    pi.inputs.bun2nix.inputs.treefmt-nix.follows = "treefmt-nix";

    agenix.url = "github:ryantm/agenix";
    agenix.inputs.nixpkgs.follows = "nixpkgs";
    agenix.inputs.home-manager.follows = "home-manager";
    agenix.inputs.darwin.follows = "nix-darwin";
    agenix-rekey.url = "github:oddlama/agenix-rekey";
    agenix-rekey.inputs.nixpkgs.follows = "nixpkgs";
    agenix-rekey.inputs.treefmt-nix.follows = "treefmt-nix";
    agenix-rekey.inputs.flake-parts.follows = "flake-parts";

    nix-vscode-extensions.url = "github:nix-community/nix-vscode-extensions";
    nix-vscode-extensions.inputs.nixpkgs.follows = "nixpkgs";

    # Daily-refreshed Obsidian community plugins as pkgs.obsidianPlugins.<id>.
    obsidian-extensions.url = "github:karaolidis/nix-obsidian-extensions";
    obsidian-extensions.inputs.nixpkgs.follows = "nixpkgs";
    obsidian-extensions.inputs.treefmt-nix.follows = "treefmt-nix";

    nvf.url = "github:NotAShelf/nvf";
    nvf.inputs.nixpkgs.follows = "nixpkgs";

    niri.url = "github:sodiboo/niri-flake";
    niri.inputs.nixpkgs.follows = "nixpkgs";
    niri.inputs.nixpkgs-stable.follows = "nixpkgs";

    dank-material-shell.url = "github:AvengeMedia/DankMaterialShell";
    dank-material-shell.inputs.nixpkgs.follows = "nixpkgs";
    dms-plugin-registry.url = "github:AvengeMedia/dms-plugin-registry";
    dms-plugin-registry.inputs.nixpkgs.follows = "nixpkgs";

    niri-dynamic-workspaces.url = "github:nickolaj-jepsen/niri-dynamic-workspaces";
    niri-dynamic-workspaces.inputs.nixpkgs.follows = "nixpkgs";
    niri-dynamic-workspaces.inputs.flake-parts.follows = "flake-parts";
    niri-dynamic-workspaces.inputs.home-manager.follows = "home-manager";
    niri-dynamic-workspaces.inputs.niri-flake.follows = "niri";

    fnug.url = "github:nickolaj-jepsen/fnug";
    fnug.inputs.nixpkgs.follows = "nixpkgs";
    fnug.inputs.flake-parts.follows = "flake-parts";

    zero-x-cb-media.url = "github:nickolaj-jepsen/0xCB-media";
    zero-x-cb-media.inputs.nixpkgs.follows = "nixpkgs";

    # Overridden at build time by `just bootstrap-iso <host>` to inject the
    # decrypted host SSH key into a host-specific bootstrap ISO. The default
    # points at an empty directory so the flake evaluates without any override.
    # `?narHash=` pins this relative path to an *immutable* lock: without it the
    # lock is "mutable" and immutable consumers of this flake reject it ("lock
    # file contains mutable lock"). Recompute via `nix hash path
    # ./installer/empty-payload` if that directory's contents ever change.
    bootstrap-payload.url = "path:./installer/empty-payload?narHash=sha256-Q3QXOoy+iN4VK2CflvRulYvPZXYgF0dO7FoF7CvWFTA=";
    bootstrap-payload.flake = false;
  };
}
