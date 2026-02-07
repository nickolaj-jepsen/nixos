{inputs, ...}: {
  imports = [
    inputs.flake-parts.flakeModules.easyOverlay
    ./claude-code.nix
    ./neovim-plugins.nix
    ./fish-plugins.nix
    ./bambu-studio.nix
    ./home-assistant.nix
  ];

  flake.nixosModules.overlays = _: {
    nixpkgs.overlays = [
      inputs.nix-vscode-extensions.overlays.default
      inputs.nur.overlays.default
      inputs.niri.overlays.niri
      inputs.self.overlays.default
    ];
  };
}
