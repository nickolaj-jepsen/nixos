{inputs, ...}: {
  nixpkgs.overlays = [
    inputs.nix-vscode-extensions.overlays.default
    inputs.nur.overlays.default
    inputs.niri.overlays.niri
  ];
}
