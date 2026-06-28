{
  # Ghostty, VS Code, and the fish/bobthefish prompt all request "Hack Nerd Font"
  # by name; without it macOS silently falls back and the prompt glyphs render as
  # tofu. macOS reads font files directly, so fonts.packages (-> /Library/Fonts)
  # is enough — no fontconfig.
  flake.modules.darwin.fonts = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.fireproof.desktop.enable {
      fonts.packages = [pkgs.nerd-fonts.hack];
    };
  };

  flake.modules.nixos.fonts = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.fireproof.desktop.enable {
      fonts.enableDefaultPackages = true;
      fonts.packages = with pkgs; [
        nerd-fonts.hack
        # DMS theme.nix requests "Inter Variable" as the shell UI font; without
        # this the whole bar/launcher/control-center silently falls back to
        # DejaVu Sans. The `inter` package registers the "Inter Variable" family.
        inter
      ];
      # Pin generic-family fallbacks so apps asking for "sans-serif"/"monospace"
      # (GTK/Qt, web defaults) resolve to our fonts rather than fontconfig's guess.
      fonts.fontconfig.defaultFonts = {
        sansSerif = ["Inter"];
        monospace = ["Hack Nerd Font Mono"];
        emoji = ["Noto Color Emoji"];
      };
    };
  };
}
