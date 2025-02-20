{inputs, ...}: {
  imports = [inputs.agenix-rekey.flakeModule];

  perSystem = {
    system,
    pkgs,
    ...
  }: {
    devShells.default = pkgs.mkShell {
      inherit system;

      packages = [
        pkgs.nix
        pkgs.nixos-rebuild
        pkgs.nixos-rebuild
        pkgs.nh
      ];
    };
  };
}
