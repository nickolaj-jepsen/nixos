{inputs, ...}: {
  # Declares disko.* for the hosts' disk-configuration.nix cards.
  flake.modules.nixos.disko = inputs.disko.nixosModules.disko;
}
