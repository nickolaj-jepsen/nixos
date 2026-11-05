# mdfried: terminal markdown viewer drawing images (and Mermaid) over the kitty
# graphics protocol. Mermaid goes through pele (pkgs/pele) and resvg rather than
# mdfried's built-in renderer, which hardcodes its own dark palette.
{
  flake.modules.homeManager.mdfried = {
    config,
    lib,
    pkgs,
    ...
  }: let
    c = config.fireproof.theme.colors;
    hex = name: "#${c.${name}}";
    inherit (config.fireproof.theme) font;

    peleVars = {
      bg = hex "bg";
      fg = hex "fg";
      muted = hex "muted";
      line = hex "fgAlt";
      surface = hex "bgAlt";
      surface-alt = hex "ui";
      border = hex "uiAlt";
      accent = hex "accent";
      critical = hex "red";
      error = hex "red";
      series-1 = hex "blue";
      series-2 = hex "orange";
      series-3 = hex "green";
      series-4 = hex "red";
      series-5 = hex "cyan";
      series-6 = hex "yellow";
      series-7 = hex "purple";
      series-8 = hex "magenta";
    };

    # mdfried runs this with `sh -c`, Mermaid on stdin and a PNG expected on stdout.
    mermaid = lib.concatStringsSep " " (
      [(lib.getExe pkgs.pele)]
      ++ lib.mapAttrsToList (name: value: lib.escapeShellArg "--var=${name}=${value}") peleVars
      ++ [
        (lib.escapeShellArg "--font=${font.monoFamily}")
        # Lays labels out for a monospaced font; most advance 0.6em per glyph.
        "--mono-advance=0.6"
        "|"
        (lib.getExe pkgs.resvg)
        "--quiet --zoom 2"
        "--skip-system-fonts --use-fonts-dir ${font.package}/share/fonts"
        # resvg falls back to Arial & co. otherwise, which aren't loaded, and drops the text.
        (lib.escapeShellArg "--font-family=${font.monoFamily}")
        (lib.escapeShellArg "--sans-serif-family=${font.monoFamily}")
        (lib.escapeShellArg "--monospace-family=${font.monoFamily}")
        (lib.escapeShellArg "--background=${hex "bg"}")
        "- -c"
      ]
    );

    settings = {
      font_family = font.family;
      enable_mouse_capture = true;
      inherit mermaid;
      theme = {
        header_color = hex "accent";
        prefix_color = hex "accent";
        emphasis_color = hex "fg";
        link_fg = hex "blue";
        link_bg = hex "bgAlt";
        code_fg = hex "green";
        code_bg = hex "bgAlt";
        hr_color = hex "uiAlt";
        table_border_color = hex "uiAlt";
        table_header_color = hex "whiteAlt";
        blockquote_colors = map hex ["accent" "orange" "yellow" "green" "cyan" "purple"];
      };
    };
    configFile = (pkgs.formats.toml {}).generate "mdfried-config.toml" settings;
  in {
    config = lib.mkIf config.fireproof.dev.enable (lib.mkMerge [
      {home.packages = [pkgs.mdfried];}
      # confy's config dir: XDG on Linux, ProjectDirs("rs", "", "mdfried") on macOS.
      # force: a run before this leaf leaves mdfried's own font-only config there,
      # which otherwise aborts the whole home-manager activation.
      (lib.mkIf pkgs.stdenv.isDarwin {
        home.file."Library/Application Support/rs.mdfried/config.toml" = {
          source = configFile;
          force = true;
        };
      })
      (lib.mkIf (!pkgs.stdenv.isDarwin) {
        xdg.configFile."mdfried/config.toml" = {
          source = configFile;
          force = true;
        };
      })
    ]);
  };
}
