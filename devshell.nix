{inputs, ...}: {
  perSystem = {
    pkgs,
    system,
    ...
  }: {
    devShells.default = pkgs.mkShell {
      name = "nixos-config";
      packages = with pkgs; [
        # Nix tools
        nil # Nix LSP
        alejandra # Nix formatter
        nix-diff # Compare derivations
        nix-tree # Visualize dependencies
        nvd # Nix version diff
        nix-output-monitor # Pretty `nix build` output for `just build`
        nurl # Generate Nix fetcher calls from URLs

        # Secrets management
        inputs.agenix.packages.${system}.default
        age
        rage # Used by `just age`
        age-plugin-yubikey # YubiKey plugin discovered via PATH by rage

        # Deployment
        just

        # Git
        git
      ];

      shellHook = ''
        echo "🔧 NixOS Configuration Development Shell"
        echo "   Run 'just' to see available commands"
      '';
    };
  };
}
