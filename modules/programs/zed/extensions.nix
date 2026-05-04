{
  config,
  lib,
  pkgs,
  ...
}: {
  config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.dev.enable) {
    fireproof.home-manager.programs.zed-editor = {
      enable = true;
      package = pkgs.unstable.zed-editor;
      installRemoteServer = true;

      extensions = [
        # Languages
        "nix"
        "just"
        "toml"
        "basher"

        # Python (matches the pyrefly + ruff setup from VSCode)
        "pyrefly"

        # Icons (theme is defined locally in ./theme.nix)
        "seti-icons"

        # Spell / grammar check (replaces cSpell)
        "harper"
      ];

      extraPackages = with pkgs; [
        # Nix
        nil

        # Python
        ruff
        unstable.basedpyright

        # JS / TS / JSON / CSS / HTML
        nodePackages.typescript-language-server
        nodePackages.prettier
        vscode-langservers-extracted

        # YAML
        yaml-language-server
      ];
    };
  };
}
