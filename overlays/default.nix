{
  inputs,
  lib,
  ...
}: {
  imports = [
    inputs.flake-parts.flakeModules.easyOverlay
    # Auto-import every overlay module here, except this file itself.
    (inputs.import-tree.filter (p: !lib.hasSuffix "/default.nix" (toString p)) ./.)
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
          inherit (final.stdenv.hostPlatform) system;
          config.allowUnfree = true;
        };
      })
    ];
  };
}
