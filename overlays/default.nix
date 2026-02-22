{inputs, ...}: {
  imports = [
    inputs.flake-parts.flakeModules.easyOverlay
    ./claude-code.nix
    ./neovim-plugins.nix
    ./fish-plugins.nix
    ./bambu-studio.nix
    ./home-assistant.nix
    ./ghostty.nix
    ./gh-aw.nix
  ];

  flake.nixosModules.overlays = _: {
    nixpkgs.overlays = [
      inputs.nix-vscode-extensions.overlays.default
      inputs.nur.overlays.default
      inputs.niri.overlays.niri
      inputs.fnug.overlays.default
      inputs.self.overlays.default
    ];
  };
}
