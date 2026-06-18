{
  description = "NixOS configuration";

  outputs = {flake-parts, ...} @ inputs: let
    inherit (inputs.nixpkgs) lib;
    # Folder-as-aspect stamper. Every file under ./modules is a self-declaring
    # dendritic module (an attrset with `flake`); its aspect is derived from where
    # it lives (first path segment under ./modules, or the filename stem for a file
    # placed directly in ./modules) and stamped onto `flake.aspectTags.<name>` for
    # every module name the file declares. The folder is authoritative: folderTags
    # is merged last (recursiveUpdate m folderTags), so a leaf can't override its
    # own tag — change membership by moving the file, never by hand.
    wrapAspect = path: let
      m = import path;
      rel = lib.removeSuffix ".nix" (lib.removePrefix (toString ./modules + "/") (toString path));
      aspect = lib.head (lib.splitString "/" rel);
      names = lib.unique (
        (lib.attrNames (m.flake.modules.nixos or {}))
        ++ (lib.attrNames (m.flake.modules.homeManager or {}))
      );
      folderTags.flake.aspectTags = lib.genAttrs names (_: [aspect]);
    in
      lib.recursiveUpdate m folderTags;
  in
    flake-parts.lib.mkFlake {inherit inputs;} {
      imports = [
        inputs.flake-parts.flakeModules.modules
        inputs.agenix-rekey.flakeModule
        ./formatter.nix
        ./devshell.nix
        ./docs.nix
        ./aspects.nix
        ./portability-check.nix
        ./hosts
        ./overlays
        ((inputs.import-tree.map wrapAspect) ./modules)
      ];
      systems = [
        "x86_64-linux"
      ];
    };

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/release-26.05";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";

    nix-index-database.url = "github:nix-community/nix-index-database";
    nix-index-database.inputs.nixpkgs.follows = "nixpkgs";

    nixos-generators.url = "github:nix-community/nixos-generators";
    nixos-generators.inputs.nixpkgs.follows = "nixpkgs";

    nixos-facter-modules.url = "github:numtide/nixos-facter-modules";

    home-manager.url = "github:nix-community/home-manager/release-26.05";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    nur.url = "github:nix-community/NUR";
    nur.inputs.nixpkgs.follows = "nixpkgs";
    nur.inputs.flake-parts.follows = "flake-parts";

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

    agenix.url = "github:ryantm/agenix";
    agenix.inputs.nixpkgs.follows = "nixpkgs";
    agenix.inputs.home-manager.follows = "home-manager";
    agenix-rekey.url = "github:oddlama/agenix-rekey";
    agenix-rekey.inputs.nixpkgs.follows = "nixpkgs";
    agenix-rekey.inputs.treefmt-nix.follows = "treefmt-nix";
    agenix-rekey.inputs.flake-parts.follows = "flake-parts";

    nix-vscode-extensions.url = "github:nix-community/nix-vscode-extensions";
    nix-vscode-extensions.inputs.nixpkgs.follows = "nixpkgs";

    niri.url = "github:sodiboo/niri-flake";
    niri.inputs.nixpkgs.follows = "nixpkgs";

    dgop.url = "github:AvengeMedia/dgop";
    dgop.inputs.nixpkgs.follows = "nixpkgs";

    dank-material-shell.url = "github:AvengeMedia/DankMaterialShell";
    dank-material-shell.inputs.nixpkgs.follows = "nixpkgs";
    dms-plugin-registry.url = "github:AvengeMedia/dms-plugin-registry";
    dms-plugin-registry.inputs.nixpkgs.follows = "nixpkgs";

    niri-dynamic-workspaces.url = "github:nickolaj-jepsen/niri-dynamic-workspaces";
    niri-dynamic-workspaces.inputs.nixpkgs.follows = "nixpkgs";

    fnug.url = "github:nickolaj-jepsen/fnug";
    fnug.inputs.nixpkgs.follows = "nixpkgs";

    zero-x-cb-media.url = "github:nickolaj-jepsen/0xCB-media";
    zero-x-cb-media.inputs.nixpkgs.follows = "nixpkgs";

    # Overridden at build time by `just bootstrap-iso <host>` to inject the
    # decrypted host SSH key into a host-specific bootstrap ISO. The default
    # points at an empty directory so the flake evaluates without any override.
    bootstrap-payload.url = "path:./hosts/bootstrap/empty-payload";
    bootstrap-payload.flake = false;
  };
}
