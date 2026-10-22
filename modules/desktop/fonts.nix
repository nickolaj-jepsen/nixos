{
  # Terminal, editor and prompt configs request the theme font by family name;
  # without it macOS silently falls back and the prompt glyphs render as
  # tofu. macOS reads font files directly, so fonts.packages (-> /Library/Fonts)
  # is enough — no fontconfig.
  flake.modules.darwin.fonts = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf config.fireproof.desktop.enable {
      fonts.packages = [
        config.fireproof.theme.font.package
        config.fireproof.theme.font.sans.package
      ];
    };
  };

  flake.modules.nixos.fonts = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf config.fireproof.desktop.enable {
      fonts.enableDefaultPackages = true;
      fonts.packages = [
        config.fireproof.theme.font.package
        config.fireproof.theme.font.sans.package
      ];
      # Pin generic-family fallbacks so apps asking for "sans-serif"/"monospace"
      # (GTK/Qt, web defaults) resolve to our fonts rather than fontconfig's guess.
      fonts.fontconfig.defaultFonts = {
        sansSerif = [config.fireproof.theme.font.sans.family];
        monospace = [config.fireproof.theme.font.monoFamily];
        emoji = ["Noto Color Emoji"];
      };
    };
  };
}
