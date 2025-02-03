{
  inputs,
  config,
  lib,
  hostname,
  ...
}: {
  perSystem = {
    pkgs,
    config,
    config',
    ...
  }: {
      agenix-rekey.nixosConfigurations = inputs.self.nixosConfigurations;
    devShells.default = pkgs.mkShellNoCC {

          
      packages = [
        pkgs.nix
        pkgs.nixos-rebuild
        pkgs.nixos-rebuild
        pkgs.nh
        pkgs.just
        config.agenix-rekey.package
        config.agenix-rekey.agePackage
      ];
      AGENIX_REKEY_ADD_TO_GIT = "true";
    };
  };
}
