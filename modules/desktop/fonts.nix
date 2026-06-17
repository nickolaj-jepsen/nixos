{
  flake.aspectTags.fonts = ["desktop"];
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
