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

          toolbar = {
            code_actions = false;
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
          buffer_font_size = 14;
          buffer_line_height.custom = 1.5;
          ui_font_family = config.fireproof.theme.font.family;
          ui_font_size = 14;

          # Editor behavior
          cursor_blink = true;
          cursor_animation.enabled = true;
          scroll_beyond_last_line = "one_page";
          sticky_scroll.enabled = true;
          colorize_brackets = true;
          inlay_hints = {
            enabled = true;
            show_background = false;
            # VSCode's "onUnlessPressed": hidden while Ctrl+Alt is held.
            toggle_on_modifiers_press = {
              control = true;
              alt = true;
            };
          };
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
          ];

          # Panels
          project_panel = {
            git_status_indicator = true;
            diagnostic_badges = false;
            bold_folder_labels = false;
            git_status = true;
            hide_gitignore = false;
            indent_size = 16;
            dock = "left";
          };
          outline_panel.dock = "left";
          collaboration_panel.dock = "left";
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
            inline_blame.enabled = true;
            git_gutter = "tracked_files";
          };

          # Terminal
          terminal = {
            shell.program = "fish";
            # Ghostty's settings type wraps every value in a list.
            font_size = lib.head (lib.toList config.programs.ghostty.settings.font-size);
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

          # AI — Claude Code (ACP) is the primary agent, opened via ctrl-alt-c.
          # The native agent panel falls back to Anthropic with Copilot Chat as
          # an alternative model option (sign in to both via the UI once).
          agent = {
            dock = "right";
            default_profile = "ask";
            default_model = {
              provider = "anthropic";
              model = "claude-sonnet-5-5";
            };
          };

          agent_servers = {
            "claude-acp" = {
              type = "registry";
              default_config_options = {
                mode = "auto";
              };
            };
          };
        };

        userKeymaps = [
          {
            context = "Editor";
            bindings = {
              "ctrl-shift-p" = "editor::Format";
            };
          }
          {
            bindings = {
              "ctrl-alt-c" = [
                "agent::NewExternalAgentThread"
                {agent = {custom = {name = "claude-acp";};};}
              ];
            };
          }
        ];
      };
    };
  };
}
