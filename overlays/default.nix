{inputs, ...}: {
  imports = [
    inputs.flake-parts.flakeModules.easyOverlay
    ./claude-code.nix
    ./github-copilot-cli.nix
    ./neovim-plugins.nix
    ./fish-plugins.nix
    ./bambu-studio.nix
    ./home-assistant.nix
    ./gh-aw.nix
  ];

  flake.nixosModules.overlays = _: {
    nixpkgs.overlays = [
      inputs.nix-vscode-extensions.overlays.default
      inputs.nur.overlays.default
      inputs.niri.overlays.niri
      inputs.fnug.overlays.default
      inputs.self.overlays.default
      (final: _prev: {
        unstable = import inputs.nixpkgs-unstable {
          inherit (final) system;
          config.allowUnfree = true;
        };
      })
    ];
  };
}
