{
  inputs,
  config,
  ...
}: {
  # The generic installer ISO: a live image for `just deploy-remote` (root SSH with
  # password `nixos`) and for a hand-driven nixos-install. It is not a host, so it is
  # built here rather than through the host resolver:
  #   nix build .#nixosConfigurations.bootstrap.config.system.build.isoImage
  #
  # Module list is deliberately slim: the upstream installation-cd plus only the two
  # dendritic leaves the ISO actually benefits from — `fireproof-options` (option
  # decls) and `nix` (its substituters, so an install pulls from attic instead of
  # compiling on the live USB). `fireproof.username` feeds that leaf's trusted-users.
  config.flake.nixosConfigurations.bootstrap = inputs.nixpkgs.lib.nixosSystem {
    specialArgs = {inherit inputs;};
    modules = [
      {nixpkgs.hostPlatform = "x86_64-linux";}
      {fireproof.username = "nixos";}
      config.flake.modules.nixos.fireproof-options
      config.flake.modules.nixos.nix
      ./iso.nix
    ];
  };
}
