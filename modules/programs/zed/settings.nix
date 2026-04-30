{
  config,
  lib,
  ...
}: {
  config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.dev.enable) {
    fireproof.home-manager.programs.zed-editor = {
      userSettings = {
        # General
        auto_update = false; # Managed by Nix
        telemetry = {
          diagnostics = false;
          metrics = false;
        };
        restore_on_startup = "last_session";
        proxy = "";
        window_decorations = "client";
        use_system_window_tabs = false;
        bottom_dock_layout = "contained";

        # Theme / UI — Flexoki theme defined in ./theme.nix mirrors the VSCode workbench
        base_keymap = "JetBrains";
        icon_theme = "Seti Icon Theme";

        title_bar = {
          button_layout = "platform_default";
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

        # Font (matches VSCode config)
        buffer_font_family = "Hack Nerd Font";
        buffer_font_size = 14;
        buffer_line_height.custom = 1.5;
        ui_font_family = "Hack Nerd Font";
        ui_font_size = 14;

        # Editor behavior
        cursor_blink = true;
        scroll_beyond_last_line = "one_page";
        inlay_hints = {
          enabled = true;
          show_background = false;
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
          blinking = "on";
          cursor_shape = "bar";
        };

        # Languages
        languages = {
          Python = {
            language_servers = ["pyrefly" "ruff" "basedpyright" "!pylsp"];
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
          JavaScript = {formatter = "prettier";};
          TypeScript = {formatter = "prettier";};
          TSX = {formatter = "prettier";};
          JSON = {formatter = "prettier";};
          JSONC = {formatter = "prettier";};
          CSS = {formatter = "prettier";};
          YAML = {formatter = "prettier";};
          Markdown = {formatter = "prettier";};
        };

        # Language servers
        lsp = {
          nil = {
            settings = {
              formatting.command = ["nix" "fmt" "--"];
            };
          };
        };

        # AI — Claude Code (ACP) is the primary agent, opened via ctrl-alt-c.
        # The native agent panel falls back to Anthropic with Copilot Chat as
        # an alternative model option (sign in to both via the UI once).
        agent = {
          dock = "right";
          default_profile = "ask";
          default_model = {
            provider = "anthropic";
            model = "claude-sonnet-4-6";
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

        # Auto-installed extensions (Zed-side; Nix-managed list lives in extensions.nix)
        auto_install_extensions = {
          basedpyright = true;
          basher = true;
          biome = true;
          "css-modules-kit" = true;
          "darcula-dark" = true;
          dockerfile = true;
          env = true;
          fish = true;
          harper = true;
          "jetbrains-icons" = true;
          "jetbrains-new-ui-icons" = true;
          "jetbrains-themes" = true;
          just = true;
          "just-ls" = true;
          "mcp-server-linear" = true;
          nix = true;
          pyrefly = true;
          "seti-icons" = true;
          toml = true;
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
}
