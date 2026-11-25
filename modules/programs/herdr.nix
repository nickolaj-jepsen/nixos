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
    # Walkthrough v0.10.0. Updates are explicit rev/hash bumps, never a runtime clone.
    walkthrough = pkgs.fetchFromGitHub {
      owner = "dmazlum";
      repo = "herdr-walkthrough";
      rev = "8d35fd16c225dfe68769a0e8fa85a103bcac013e";
      hash = "sha256-GsPw5aJb0YzMxfe3whXmc8yYSETk9MnILgxgahEoJqI=";
    };
    keys = json.generate "herdr-mod-keys.json" {
      global.${
        if pkgs.stdenv.isDarwin
        then "cmd-shift-k"
        else "ctrl-alt-k"
      } = "mod.open:walkthrough";
      global.${
        if pkgs.stdenv.isDarwin
        then "cmd-i"
        else "ctrl-alt-shift-p"
      } = "mod.open:new-chat";
      global.${
        if pkgs.stdenv.isDarwin
        then "cmd-shift-g"
        else "ctrl-alt-shift-g"
      } = "mod.open:gitview-sidebar";
      global.${
        if pkgs.stdenv.isDarwin
        then "cmd-g"
        else "ctrl-alt-g"
      } = "mod.open:gitview-tab";
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
    uiFiles =
      lib.filter
      (source: !(lib.elem (baseNameOf source) [".gitignore" "gpui-kit.d.ts" "jsconfig.json"]))
      (lib.filesystem.listFilesRecursive ./herdr-ui);
    mergeConfig = pkgs.writeShellApplication {
      name = "herdr-merge-config";
      runtimeInputs = [pkgs.jq];
      text = ''
        file=$1
        defaults=$2
        mkdir -p "$(dirname "$file")"
        tmp=$(mktemp "$file.XXXXXX")
        trap 'rm -f "$tmp"' EXIT
        if [ -f "$file" ]; then
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
    config = lib.mkIf config.fireproof.desktop.enable {
      home.packages = [
        pkgs.unstable.herdr-desktop
        pkgs.unstable.herdr-core
      ];

      # Keep directories writable for metadata and image caches.
      home.file =
        lib.genAttrs (map (name: "${config.xdg.configHome}/herdr-app/mods/${name}") [
          "gitview"
          "gitview-diff"
          "gitview-agents"
          "gitview-ask"
          "gitview-sidebar"
          "gitview-tab"
          "gitview-keys"
          "gitview-mark"
          "gitview-tracing"
        ]) (path: {
          source = "${pkgs.herdr-gitview}/share/herdr-gitview/mods/${baseNameOf path}";
          recursive = true;
        });
      xdg.configFile."herdr-app/mods/gitview/config.json".source = json.generate "herdr-gitview-config.json" {
        bin = lib.getExe pkgs.herdr-gitview;
        herdr_app = lib.getExe pkgs.unstable.herdr-desktop;
        hc = lib.getExe' pkgs.unstable.herdr-core "hc";
      };

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

      # Personal UI sources live here, not in Herdr's shipped files. Deploy real
      # writable files: the app generates metadata alongside mods, and its layout
      # editor must be able to save. Live source edits reset on the next activation;
      # make persistent changes in herdr-ui. Keep machine/session/click state out.
      home.activation.herdrUi = lib.hm.dag.entryAfter ["linkGeneration"] ''
        ${lib.concatMapStringsSep "\n" (source: let
            relative = lib.removePrefix "${toString ./herdr-ui}/" (toString source);
            target = "${config.xdg.configHome}/herdr-app/${relative}";
          in ''
            run ${lib.getExe' pkgs.coreutils "install"} -Dm644 ${source} ${lib.escapeShellArg target}
          '')
          uiFiles}
        run ${lib.getExe mergeConfig} ${lib.escapeShellArg "${config.xdg.configHome}/herdr-app/shared.json"} ${uiDefaults} --defaults
      '';

      # Herdr writes settings/keys from its UI; merge our entries into writable
      # files. Shipped layouts are replaced on launch, so leave them alone.
      home.activation.herdrTheme = lib.hm.dag.entryAfter ["linkGeneration"] ''
        run ${lib.getExe mergeConfig} ${lib.escapeShellArg "${config.xdg.configHome}/herdr-app/settings.json"} ${settings}
        run ${lib.getExe mergeConfig} ${lib.escapeShellArg "${config.xdg.configHome}/herdr-app/keys.json"} ${keys}
        run ${lib.getExe mergeConfig} ${lib.escapeShellArg "${config.xdg.configHome}/herdr-app/programs.json"} ${programs}
      '';
    };
  };
}
