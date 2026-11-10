{
  flake.modules.homeManager.zed-settings = {
    config,
    lib,
    pkgs,
    ...
  }: let
    # Prettier-compatible, and the same formatter neovim's conform uses. Resolved
    # from PATH, which zed's extraPackages owns.
    oxfmt.external = {
      command = "oxfmt";
      arguments = ["--stdin-filepath" "{buffer_path}"];
    };
    harperDictionary = pkgs.writeText "harper-dictionary.txt" (lib.concatLines (import ../_spell-words.nix));
    bufferFontSize = 14;
  in {
    config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.dev.enable) {
      programs.zed-editor = {
        userSettings = {
          # General
          # nixpkgs pins the Linux build; the darwin cask updates itself (brew upgrade skips it).
          auto_update = pkgs.stdenv.isDarwin;
          telemetry = {
            diagnostics = false;
            metrics = false;
          };
          restore_on_startup = "last_session";
          # A path inside an already-open project still lands in that project's window.
          cli_default_open_behavior = "new_window";
          # Closing the last tab keeps the window; the window manager closes it.
          when_closing_with_no_tabs = "keep_window_open";
          proxy = "";
          window_decorations = lib.mkIf pkgs.stdenv.isLinux "client";
          use_system_window_tabs = false;
          bottom_dock_layout = "contained";

          # Theme / UI — Flexoki theme defined in ./theme.nix mirrors the VSCode workbench
          base_keymap = "JetBrains";
          icon_theme = "Seti Icon Theme";

          title_bar = {
            # niri manages the window, like VSCode's hidden controlsStyle.
            button_layout = "";
            show_menus = false;
            show_branch_status_icon = false;
          };

          indent_guides = {
            background_coloring = "disabled";
          };

          minimap = {
            max_width_columns = 80;
            thumb = "always";
            display_in = "active_editor";
            show = "auto";
          };

          # Font
          buffer_font_family = config.fireproof.theme.font.family;
          buffer_font_size = bufferFontSize;
          buffer_line_height.custom = 1.5;
          # VSCode's workbench font: the system sans (Inter via fontconfig on NixOS).
          ui_font_family =
            if pkgs.stdenv.isDarwin
            then ".SystemUIFont"
            else "Inter";
          ui_font_size = 14;

          # Unified diffs match how git and most review tools show a patch.
          diff_view_style = "unified";

          # Editor behavior
          cursor_blink = true;
          scroll_beyond_last_line = "one_page";
          sticky_scroll.enabled = true;
          colorize_brackets = true;
          inlay_hints.enabled = false;

          # Error Lens equivalent; capped at info so harper's hints stay squiggles.
          diagnostics.inline = {
            enabled = true;
            max_severity = "info";
          };
          show_whitespaces = "boundary";
          format_on_save = "on";
          remove_trailing_whitespace_on_save = true;
          ensure_final_newline_on_save = true;
          autosave.after_delay.milliseconds = 1000;

          # Files
          file_scan_exclusions = [
            "**/.git"
            "**/.DS_Store"
            "**/node_modules"
            "**/.direnv"
            "**/__pycache__"
            "**/*.egg-info"
            "**/*.js.map"
            "**/*.mjs.map"
            "**/*.cjs.map"
            # Build outputs point into /nix/store, which is never worth indexing.
            "**/result"
            "**/result-*"
            # Agent session scratch: reaped by age, not worth searching.
            "**/.agents/tmp"
          ];
          # The agent notes are a symlinked folder, `.agents/store`; `expanded` only
          # scans it once it is clicked open, so its files never showed in search or
          # in the tree until then. `always` follows every link, which the exclusions
          # above keep from reaching build outputs.
          scan_symlinks = "always";

          # Panels
          project_panel = {
            git_status_indicator = true;
            folder_indicator = "chevron";
            diagnostic_badges = false;
            bold_folder_labels = false;
            git_status = true;
            hide_gitignore = false;
            indent_size = 16;
            dock = "left";
          };
          outline_panel.dock = "left";
          collaboration_panel = {
            dock = "left";
            button = false;
          };
          git_panel = {
            status_style = "icon";
            collapse_untracked_diff = false;
            tree_view = false;
            dock = "left";
          };

          # Tabs
          tab_bar.show = true;
          tabs = {
            file_icons = true;
            close_position = "right";
            git_status = true;
            show_close_button = "hover";
          };
          max_tabs = 10;

          # Git
          git = {
            # Blame in the status bar rather than as a ghost line in the buffer.
            inline_blame = {
              enabled = true;
              location = "status_bar";
            };
            git_gutter = "tracked_files";
          };

          # Terminal
          terminal = {
            shell.program = "fish";
            # Larger than Ghostty's 11: the panel is small and read at a glance.
            font_size = 14;
            blinking = "on";
            cursor_shape = "bar";
          };

          # Languages
          languages = {
            Python = {
              language_servers = ["pyrefly" "ruff" "!pylsp"];
              format_on_save = "on";
              formatter.language_server.name = "ruff";
            };
            Nix = {
              language_servers = ["nil"];
              formatter.external = {
                command = "nix";
                arguments = ["fmt" "--"];
              };
            };
            JavaScript = {formatter = oxfmt;};
            TypeScript = {formatter = oxfmt;};
            TSX = {formatter = oxfmt;};
            JSON = {formatter = oxfmt;};
            JSONC = {formatter = oxfmt;};
            CSS = {formatter = oxfmt;};
            SCSS = {formatter = oxfmt;};
            HTML = {formatter = oxfmt;};
            YAML = {formatter = oxfmt;};
            Markdown = {formatter = oxfmt;};
          };

          # Language servers
          lsp = {
            nil = {
              settings = {
                formatting.command = ["nix" "fmt" "--"];
              };
            };
            harper-ls.settings.harper-ls = {
              userDictPath = "${harperDictionary}";
              diagnosticSeverity = "hint";
            };
          };

          edit_predictions.provider = "copilot";

          # AI — Claude Code and pi run as external agents (ACP): each owns its
          # runtime, auth and models, and Zed brings the thread UI. Claude is
          # opened via ctrl-alt-c. The native agent panel falls back to Anthropic
          # with Copilot Chat as an alternative model option (sign in to both via
          # the UI once).
          agent = {
            dock = "right";
            default_profile = "ask";
          };
          # The agent panel defaults to 12pt; match the buffer instead.
          agent_buffer_font_size = bufferFontSize;

          # Registry agents are fetched from the ACP registry and run via npx, so
          # `node` must be on the PATH Zed is launched with. pi-acp spawns `pi`
          # from PATH (pkgs/pi-coding-agent) and reuses ~/.pi/agent config.
          agent_servers = {
            "claude-acp" = {
              type = "registry";
              default_config_options = {
                mode = "auto";
              };
            };
            "pi-acp".type = "registry";
          };
        };

        userKeymaps = [
          {
            context = "Editor";
            bindings = {
              "ctrl-shift-p" = "editor::Format";
            };
          }
          # The JetBrains base keymap puts double-shift on the command palette; this
          # is JetBrains' Search Everywhere as the user reaches for it, a file search.
          {
            context = "Workspace";
            bindings = {
              "shift shift" = "file_finder::Toggle";
            };
          }
        ];
      };
    };
  };
}
