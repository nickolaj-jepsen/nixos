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

        # Secrets management
        inputs.agenix.packages.${system}.default
        age

        # Deployment
        just

        # Git
        git
        jujutsu
      ];

      shellHook = ''
        echo "🔧 NixOS Configuration Development Shell"
        echo "   Run 'just' to see available commands"
      '';
    };
  };
}
