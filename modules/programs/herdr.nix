# Herdr: a desktop app for terminals and coding agents, plus herdr-core (the
# background program they actually run in; `hc` is its CLI). Neither is in
# nixpkgs 26.05, so both come from unstable. They are built here rather than by
# Herdr's installer, which means Herdr's own updater stays out of it — the
# nixpkgs build says so in Settings → Updates. herdr-desktop carries its
# herdr-core's store path, and herdr-core on PATH keeps `hc` beside it for
# agents in any terminal.
{inputs, ...}: {
  flake.modules.homeManager.herdr = {
    config,
    lib,
    pkgs,
    ...
  }: let
    c = config.fireproof.theme.colors;
    json = pkgs.formats.json {};
    # Walkthrough v0.10.0. Updates are explicit rev/hash bumps, never a runtime clone.
    walkthrough = pkgs.fetchFromGitHub {
      owner = "dmazlum";
      repo = "herdr-walkthrough";
      rev = "8d35fd16c225dfe68769a0e8fa85a103bcac013e";
      hash = "sha256-GsPw5aJb0YzMxfe3whXmc8yYSETk9MnILgxgahEoJqI=";
    };
    isDarwin = pkgs.stdenv.isDarwin;
    appMod =
      if isDarwin
      then "cmd"
      else "ctrl-shift";
    paneMod =
      if isDarwin
      then "cmd-alt"
      else "ctrl-alt";
    # keys.json is the entire map, not an overlay on Herdr's defaults. Spaces
    # take the familiar terminal-tab shortcuts; inner tabs stay palette-only.
    keys = json.generate "herdr-keys.json" {
      global =
        {
          "${appMod}-t" = "space.new";
          "${appMod}-w" = "pane.close";
          "ctrl-tab" = "space.next";
          "ctrl-shift-tab" = "space.prev";
          "${
            if isDarwin
            then "cmd-shift-]"
            else "ctrl-shift-right"
          }" = "space.next";
          "${
            if isDarwin
            then "cmd-shift-["
            else "ctrl-shift-left"
          }" = "space.prev";
          "f2" = "space.rename";

          "${appMod}-enter" = "pane.split:right";
          "${
            if isDarwin
            then "cmd-shift-d"
            else "ctrl-shift-d"
          }" = "pane.split:down";
          "${
            if isDarwin
            then "cmd-shift-enter"
            else "ctrl-shift-z"
          }" = "pane.zoom";

          "${
            if isDarwin
            then "cmd-shift-p"
            else "ctrl-shift-p"
          }" = "app.palette";
          # GPUI recognizes two clean Shift taps within its one-second sequence
          # timeout; Shift used with another key does not count as a tap.
          "shift shift" = "app.palette";
          "${
            if isDarwin
            then "cmd-p"
            else "ctrl-shift-k"
          }" = "mod.open:picker";
          "${
            if isDarwin
            then "cmd-,"
            else "ctrl-,"
          }" = "app.settings";
          "${appMod}-=" = "app.zoom_in";
          "${appMod}-+" = "app.zoom_in";
          "${appMod}--" = "app.zoom_out";
          "${appMod}-0" = "app.zoom_reset";
          "${appMod}-b" = "layout.toggle:sidebar";
          "ctrl-shift-l" = "layout.switch";

          "${
            if isDarwin
            then "cmd-shift-k"
            else "ctrl-alt-k"
          }" = "mod.open:walkthrough";
          "${
            if isDarwin
            then "cmd-i"
            else "ctrl-alt-shift-p"
          }" = "mod.open:new-chat";
          # The nested sidebar's Needs you list: show the agent waiting longest.
          "${
            if isDarwin
            then "cmd-shift-j"
            else "ctrl-shift-j"
          }" = "nested-spaces.next-needs";
        }
        // builtins.listToAttrs (builtins.genList (i: {
            name = "${appMod}-${toString (i + 1)}";
            value = "space.select:${toString (i + 1)}";
          })
          9)
        // builtins.listToAttrs (lib.concatMap (direction: [
          {
            name = "${paneMod}-${direction}";
            value = "pane.go:${direction}";
          }
          {
            name = "${paneMod}-shift-${direction}";
            value = "pane.swap:${direction}";
          }
        ]) ["left" "right" "up" "down"]);
      terminal =
        {
          "ctrl-shift-c" = "terminal.copy";
          "ctrl-shift-v" = "terminal.paste";
          "${appMod}-f" = "terminal.search";
          # Do not restore the default Ctrl+V image-paste or hard-coded word
          # navigation: the shell/TUI owns its input and negotiated key protocol.
          "ctrl-enter" = "terminal";
        }
        // lib.optionalAttrs isDarwin {
          "cmd-c" = "terminal.copy";
          "cmd-v" = "terminal.paste";
        };
    };
    settings = json.generate "herdr-theme-settings.json" {
      theme = "fireproof";
      appearance = "dark";
      font = config.fireproof.theme.font.family;
    };
    programs = json.generate "herdr-programs.json" {
      programs = lib.optionalAttrs config.fireproof.claude-code.work.enable {
        claude-work = {
          name = "Claude Code (work)";
          icon = "icons/claude.svg";
          run = ["claude-work"];
          tint = false;
          tile = "#1c1d21";
          color = "#ffffff";
        };
      };
    };
    uiDefaults = json.generate "herdr-ui-defaults.json" {layout = "nested";};
    uiSource = inputs.agents.packages.${pkgs.stdenv.hostPlatform.system}.herdr-ui;
    updates = config.fireproof.agents.updates;
    mergeConfig = pkgs.writeShellApplication {
      name = "herdr-merge-config";
      runtimeInputs = [pkgs.jq];
      text = ''
        file=$1
        defaults=$2
        mkdir -p "$(dirname "$file")"
        tmp=$(mktemp "$file.XXXXXX")
        trap 'rm -f "$tmp"' EXIT
        if [ "''${3:-}" = "--replace" ]; then
          cp "$defaults" "$tmp"
        elif [ -f "$file" ]; then
          jq -e 'type == "object"' "$file" >/dev/null
          if [ "''${3:-}" = "--defaults" ]; then
            jq --slurpfile defaults "$defaults" '$defaults[0] * .' "$file" > "$tmp"
          else
            jq --slurpfile defaults "$defaults" '. * $defaults[0]' "$file" > "$tmp"
          fi
        else
          cp "$defaults" "$tmp"
        fi
        chmod 600 "$tmp"
        mv "$tmp" "$file"
      '';
    };
  in {
    config = lib.mkMerge [
      (lib.mkIf config.fireproof.herdr-core.enable {
        home.packages = [pkgs.unstable.herdr-core];
      })
      (lib.mkIf config.fireproof.desktop.enable {
        home.packages = [pkgs.unstable.herdr-desktop];
        fireproof.agents.updates.ui.herdr-ui = uiSource;

        # Link the whole mod so removed upstream files disappear on upgrades too.
        # Walkthrough stores reports/preferences outside its source directory.
        xdg.configFile."herdr-app/mods/walkthrough".source = "${walkthrough}/mods/walkthrough";

        # Only install the chat and Codex-filtered launcher, not upstream's
        # replacements for the agents list, terminal menu or shipped layout.
        xdg.configFile."herdr-app/mods/new-chat".source = "${pkgs.herdr-chat}/share/herdr-chat/mods/new-chat";
        xdg.configFile."herdr-app/mods/chat" = {
          source = "${pkgs.herdr-chat}/share/herdr-chat/mods/chat";
          recursive = true;
        };
        xdg.configFile."herdr-app/mods/chat/config.json".source = json.generate "herdr-codex-chat.json" {
          host = lib.getExe pkgs.herdr-chat;
          node = lib.getExe pkgs.nodejs;
          hc = lib.getExe' pkgs.unstable.herdr-core "hc";
          codex = lib.getExe pkgs.unstable.codex;
          version = pkgs.herdr-chat.version;
          # Release-channel installs can download and run an upstream installer.
          channel = "nix";
        };

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

        # Share ownership and version selection with `agents update herdr-ui`: a
        # switch must not silently replace a published override with the baseline.
        # Herdr watches these writable files and reloads changes itself. Persistent
        # edits belong in agents/apps/herdr-ui, not in the deployed copies.
        home.activation.herdrUi = lib.hm.dag.entryAfter ["linkGeneration"] ''
          run ${lib.getExe updates.cli} deploy-ui herdr-ui
          # Only seed a missing layout selection; Herdr owns this live state.
          if [ ! -e ${lib.escapeShellArg "${config.xdg.configHome}/herdr-app/shared.json"} ] || ! ${lib.getExe pkgs.jq} -e 'has("layout")' ${lib.escapeShellArg "${config.xdg.configHome}/herdr-app/shared.json"} >/dev/null; then
            run ${lib.getExe mergeConfig} ${lib.escapeShellArg "${config.xdg.configHome}/herdr-app/shared.json"} ${uiDefaults} --defaults
          fi
        '';

        # Herdr writes these files from its UI, so keep them writable. Settings
        # and programs merge; keys are the complete declarative map. Replacing
        # them also retires old default bindings (including inner-tab shortcuts).
        home.activation.herdrTheme = lib.hm.dag.entryAfter ["linkGeneration"] ''
          run ${lib.getExe mergeConfig} ${lib.escapeShellArg "${config.xdg.configHome}/herdr-app/settings.json"} ${settings}
          run ${lib.getExe mergeConfig} ${lib.escapeShellArg "${config.xdg.configHome}/herdr-app/keys.json"} ${keys} --replace
          run ${lib.getExe mergeConfig} ${lib.escapeShellArg "${config.xdg.configHome}/herdr-app/programs.json"} ${programs}
        '';
      })
    ];
  };
}
