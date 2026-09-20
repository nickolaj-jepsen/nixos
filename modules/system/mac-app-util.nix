# Trampolines so nix-built .app bundles (vscode) show up in Spotlight/Dock. Both modules are inert off darwin.
{inputs, ...}: {
  flake.modules.darwin.mac-app-util = inputs.mac-app-util.darwinModules.default;
  flake.modules.homeManager.mac-app-util = inputs.mac-app-util.homeManagerModules.default;
}
