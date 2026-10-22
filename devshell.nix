{self, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: {
    devShells.default = pkgs.mkShell {
      name = "nixos-config";
      # treefmt plus every formatter `nix fmt` runs, at the same versions — including
      # `just` itself, which the justfile's `minimum-version` needs newer than 26.05's.
      inputsFrom = [config.treefmt.build.devShell];
      packages = with pkgs; [
        # Nix tools
        nix-diff # Compare derivations
        nix-tree # Visualize dependencies
        nvd # Nix version diff
        nix-output-monitor # Pretty `nix build` output for `just build`
        nurl # Generate Nix fetcher calls from URLs

        # Secrets management
        config.agenix-rekey.package # `agenix rekey|edit|generate`
        rage # Used by `just age`
        age-plugin-yubikey # YubiKey plugin discovered via PATH by rage

        # Same just as treefmt's, named so a lost formatter can't take `just` with it.
        (self.lib.just system)
        python3 # `just update` / `just update-packages` scripts (stdlib only)
      ];
    };
  };
}
