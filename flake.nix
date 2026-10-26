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
        ./pkgs
        # Every file under ./modules is a self-gating dendritic leaf; see docs/modules.md.
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
    # Only for pkgs/llama-cpp-cuda; the update bot holds it back until cache.nixos-cuda.org has that build.
    nixpkgs-cuda.url = "github:nixos/nixpkgs/nixos-unstable";

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

    # Plain git: gitlab: resolves the branch through GitLab's API, which sits behind a Cloudflare challenge since 2026-10-11.
    firefox-addons.url = "git+https://gitlab.com/rycee/nur-expressions.git?shallow=1&dir=pkgs/firefox-addons";
    firefox-addons.inputs.nixpkgs.follows = "nixpkgs";

    nixos-wsl.url = "github:nix-community/NixOS-WSL/main";
    nixos-wsl.inputs.nixpkgs.follows = "nixpkgs";

    # phone-vm's guest contract (kernel, image, agent); m0-m1 until it lands on main.
    pocketnix.url = "github:nickolaj-jepsen/pocketnix/m0-m1";
    pocketnix.inputs.nixpkgs.follows = "nixpkgs";

    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";

    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";

    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";

    # Recursively imports every `.nix` file under a directory (skipping any
    # `_`-prefixed path), so module/host trees are auto-imported
    # instead of maintained as hand-written `imports = [ … ]` lists.
    import-tree.url = "github:vic/import-tree";

    # Tracks `dev`: nixpkgs is still on 1.x. Upstream pins nixpkgs-unstable, whose
    # bun its node_modules hash is computed against; there's no binary cache.
    opencode.url = "github:anomalyco/opencode";
    opencode.inputs.nixpkgs.follows = "nixpkgs-unstable";

    agenix.url = "github:ryantm/agenix";
    agenix.inputs.nixpkgs.follows = "nixpkgs";
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
    # Obsidian vault agent skills, tracked at HEAD.
    obsidian-skills.url = "github:kepano/obsidian-skills";
    obsidian-skills.flake = false;

    nvf.url = "github:NotAShelf/nvf";
    nvf.inputs.nixpkgs.follows = "nixpkgs";

    niri.url = "github:sodiboo/niri-flake";
    niri.inputs.nixpkgs.follows = "nixpkgs";
    niri.inputs.nixpkgs-stable.follows = "nixpkgs";

    dank-material-shell.url = "github:AvengeMedia/DankMaterialShell";
    dank-material-shell.inputs.nixpkgs.follows = "nixpkgs";
    dms-plugin-registry.url = "github:AvengeMedia/dms-plugin-registry";
    dms-plugin-registry.inputs.nixpkgs.follows = "nixpkgs";
    walldye.url = "github:nickolaj-jepsen/walldye";
    walldye.inputs.nixpkgs.follows = "nixpkgs";

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

    # Python library for the Zwift Home Assistant integration, tracked at HEAD.
    zwift-client.url = "github:nickolaj-jepsen/zwift-client";
    zwift-client.flake = false;
  };
}
