# Herdr: a desktop app for terminals and coding agents, plus herdr-core (the
# background program they actually run in; `hc` is its CLI). Neither is in
# nixpkgs 26.05, so both come from unstable. They are built here rather than by
# Herdr's installer, which means Herdr's own updater stays out of it — the
# nixpkgs build says so in Settings → Updates. herdr-desktop carries its
# herdr-core's store path, and herdr-core on PATH keeps `hc` beside it for
# agents in any terminal.
{
  flake.modules.homeManager.herdr = {
    config,
    lib,
    pkgs,
    ...
  }: let
    c = config.fireproof.theme.colors;
    json = pkgs.formats.json {};
    settings = json.generate "herdr-theme-settings.json" {
      theme = "fireproof";
      appearance = "dark";
      font = config.fireproof.theme.font.family;
    };
    applyTheme = pkgs.writeShellApplication {
      name = "herdr-apply-theme";
      runtimeInputs = [pkgs.jq];
      text = ''
        file=$1
        mkdir -p "$(dirname "$file")"
        tmp=$(mktemp "$file.XXXXXX")
        trap 'rm -f "$tmp"' EXIT
        if [ -f "$file" ]; then
          jq -e 'type == "object"' "$file" >/dev/null
          jq --slurpfile theme ${settings} '. * $theme[0]' "$file" > "$tmp"
        else
          cp ${settings} "$tmp"
        fi
        chmod 600 "$tmp"
        mv "$tmp" "$file"
      '';
    };
  in {
    config = lib.mkIf config.fireproof.desktop.enable {
      home.packages = [
        pkgs.unstable.herdr-desktop
        pkgs.unstable.herdr-core
      ];

      xdg.configFile."herdr-app/themes/fireproof.json".source = json.generate "herdr-fireproof.json" {
        background = "#${c.bg}";
        foreground = "#${c.fg}";
        selection = "#${c.uiAlt}";
        cursor = "#${c.fg}";
        # Match Ghostty's normal and bright ANSI palettes.
        ansi = map (color: "#${color}") [
          c.black
          c.redAlt
          c.greenAlt
          c.yellowAlt
          c.blueAlt
          c.magentaAlt
          c.cyanAlt
          c.fg
          c.muted
          c.red
          c.green
          c.yellow
          c.blue
          c.magenta
          c.cyan
          c.whiteAlt
        ];
        colors = {
          # One Kitty-colored surface for panels, bars and terminals. The main
          # layout already has 8px gutters; only their canvas is lighter.
          surface = "#${c.bg}";
          canvas = "#${c.bgAlt}";
          chrome = "#${c.bg}";
          popover = "#${c.bg}";
          raised = "#${c.bg}";
          hover = "#${c.bgAlt}";
          selected = "#${c.ui}";
          border = "#${c.bgAlt}";
          input = "#${c.bg}";
          muted = "#${c.fgAlt}";
          dim = "#${c.muted}";
          accent = "#${c.accent}";
          accent_foreground = "#${c.black}";
          solid = "#${c.fg}";
          solid_foreground = "#${c.bg}";
          working = "#${c.blue}";
          blocked = "#${c.orange}";
          done = "#${c.green}";
          idle = "#${c.muted}";
          unknown = "#${c.muted}";
        };
      };

      # Herdr writes settings from its UI; keep them writable and merge only our
      # look on activation. Shipped layouts are replaced on launch, so leave them alone.
      home.activation.herdrTheme = lib.hm.dag.entryAfter ["linkGeneration"] ''
        run ${lib.getExe applyTheme} ${lib.escapeShellArg "${config.xdg.configHome}/herdr-app/settings.json"}
      '';
    };
  };
}
