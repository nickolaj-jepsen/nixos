# Enabled when: desktop & dev
{
  config,
  lib,
  pkgsUnstable,
  ...
}: {
  config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.dev.enable) {
    fireproof.home-manager.programs.zed-editor = {
      enable = true;
      package = pkgsUnstable.zed-editor;
      extensions = [
        "basedpyright"
        "biome"
        "css-modules-kit"
        "dockerfile"
        "env"
        "fish"
        "jetbrains-themes"
        "just-ls"
        "mcp-server-linear"
        "nix"
      ];
      userSettings = {
        base_keymap = "JetBrains";
        theme = {
          mode = "dark";
          light = "JetBrains Light";
          dark = "JetBrains Dark";
        };
        ui_font_family = "Hack Nerd Font";
        buffer_font_family = "Hack Nerd Font";
        buffer_font_size = 13;
        buffer_line_height = "standard";
      };
    };
  };
}
