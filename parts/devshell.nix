{inputs, ...}: {
  imports = [inputs.agenix-rekey.flakeModule];

  perSystem = {
    config,
    system,
    pkgs,
    ...
  }: {
    # agenix-rekey.nixosConfigurations = self.nodes;
    devShells.default = pkgs.mkShell {
      inherit system;

      packages = [
        pkgs.nix
        pkgs.nixos-rebuild
        pkgs.nixos-rebuild
        pkgs.nh
        pkgs.age
        pkgs.rage
        pkgs.age-plugin-yubikey
        config.agenix-rekey.package
      ];
      env.AGENIX_REKEY_ADD_TO_GIT = true;
    };

    agenix-rekey.nixosConfigurations = inputs.self.nixosConfigurations; # (not technically needed, as it is already the default)
  };
}
