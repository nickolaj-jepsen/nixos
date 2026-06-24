# neovim via nvf. Always-on lean baseline (editing UX + nil/lua-ls + cheap
# grammars) on every host; the heavy language support layers on only when
# fireproof.neovim.full.enable (defaults to dev.enable).
{
  flake.modules.homeManager.neovim = {
    config,
    lib,
    pkgs,
    inputs,
    ...
  }: let
    full = config.fireproof.neovim.full.enable;
    c = config.fireproof.theme.colors;
  in {
    imports = [inputs.nvf.homeManagerModules.default];

    programs.nvf = {
      enable = true;
      defaultEditor = true;

      settings.vim = {
        viAlias = true;
        vimAlias = true;

        globals = {
          mapleader = " ";
          maplocalleader = " ";
        };

        options = {
          number = true;
          mouse = "a";
          clipboard = "unnamedplus";
          breakindent = true;
          undofile = true;
          ignorecase = true;
          smartcase = true;
          signcolumn = "yes";
          updatetime = 250;
          timeoutlen = 300;
          splitright = true;
          splitbelow = true;
          list = true;
          listchars = "tab:» ,trail:·,nbsp:␣";
          inccommand = "split";
          cursorline = true;
          scrolloff = 10;
          hlsearch = true;
          termguicolors = true;
          tabstop = 2;
          shiftwidth = 2;
          expandtab = true;
        };

        # Flexoki, wired from the central palette (SSOT with the rest of the desktop).
        theme = {
          enable = true;
          name = "base16";
          base16-colors = {
            base00 = "#${c.bg}";
            base01 = "#${c.bgAlt}";
            base02 = "#${c.ui}";
            base03 = "#${c.muted}";
            base04 = "#${c.fgAlt}";
            base05 = "#${c.fg}";
            base06 = "#${c.whiteAlt}";
            base07 = "#${c.white}";
            base08 = "#${c.red}";
            base09 = "#${c.orange}";
            base0A = "#${c.yellow}";
            base0B = "#${c.green}";
            base0C = "#${c.cyan}";
            base0D = "#${c.blue}";
            base0E = "#${c.purple}";
            base0F = "#${c.magenta}";
          };
        };

        lsp = {
          enable = true;
          formatOnSave = true;
        };

        # nvf defaults diagnostics to underline-only; surface them with signs +
        # current-line virtual_lines (needs nvim >=0.11; we ship 0.12).
        diagnostics = {
          enable = true;
          config = {
            severity_sort = true;
            update_in_insert = false;
            underline = true;
            signs.text = lib.generators.mkLuaInline ''
              {
                [vim.diagnostic.severity.ERROR] = " ",
                [vim.diagnostic.severity.WARN]  = " ",
                [vim.diagnostic.severity.INFO]  = " ",
                [vim.diagnostic.severity.HINT]  = "󰌶 ",
              }
            '';
            virtual_lines = {current_line = true;};
            virtual_text = false;
          };
        };

        languages = {
          enableTreesitter = true;
          enableFormat = true;

          # Baseline (every host).
          nix.enable = true;
          nix.lsp.servers = lib.mkForce (
            if full
            then ["nixd"]
            else ["nil"]
          );
          lua.enable = true;

          # Full tier (desktop + dev-ao): heavy LSPs + their grammars.
          python = {
            enable = full;
            lsp.servers = ["pyrefly"];
            format.type = ["ruff"];
          };
          typescript.enable = full; # ts/tsx/js/jsx via typescript-language-server + prettier
          markdown = {
            enable = full;
            format.type = ["prettierd"];
          };
          json = {
            enable = full;
            format.type = ["prettierd"];
          };
          yaml.enable = full; # nvf has no yaml formatter; added via conform below
          html.enable = full; # superhtml (nvf default)
          css = {
            enable = full;
            format.type = ["prettierd"];
          };
        };

        # Baseline grammars for cheap, common filetypes that have no
        # language module enabled at baseline (highlighting only, no LSP). The
        # full-tier languages append their own grammars when enabled; lua/vim/
        # vimdoc/query come from treesitter.addDefaultGrammars.
        treesitter.grammars = with pkgs.vimPlugins.nvim-treesitter.grammarPlugins; [
          bash
          markdown
          markdown_inline
          json
          yaml
          fish
          toml
          git_config
          gitcommit
          gitignore
          regex
        ];

        # Sticky header pinning the enclosing fn/class while scrolling. Cheap (reuses
        # parsed grammars) but only earns its keep in the full-tier languages.
        treesitter.context.enable = full;

        autocomplete.blink-cmp = {
          enable = true;
          friendly-snippets.enable = true;
          setupOpts = {
            # "enter" accepts on <CR> (matches the PyCharm/VSCode aliases below);
            # mini.pairs still gets <CR> when the menu is closed.
            keymap.preset = "enter";
            appearance.nerd_font_variant = "normal";
            sources.default = ["lsp" "path" "snippets" "buffer"];
            signature.enabled = true;
            completion.documentation = {
              auto_show = true;
              auto_show_delay_ms = 200;
            };
          };
        };

        # GitHub Copilot ghost-text suggestions. Full tier only (pulls in nodejs).
        # cmp.enable wires copilot-cmp into nvim-cmp, but we run blink — so we stay
        # on inline suggestions, which are independent of the completion menu.
        # Accept <M-l>, next/prev <M-]>/<M-[>, dismiss <C-]>. Auth once: :Copilot auth.
        assistant.copilot.enable = full;

        # Languages auto-wire conform; only yaml needs a manual formatter (full only,
        # reusing the prettier the typescript module already puts on PATH).
        formatter.conform-nvim.setupOpts.formatters_by_ft = lib.optionalAttrs full {
          yaml = ["prettier"];
        };

        utility.snacks-nvim = {
          enable = true;
          setupOpts = {
            picker = {enabled = true;};
            explorer = {enabled = true;};
            indent = {enabled = true;};
            bigfile = {enabled = true;};
            notifier = {enabled = true;};
          };
        };

        # flash.nvim: modern easymotion. s jump, S treesitter, r/R remote
        # (operator/visual), <c-s> toggle — nvf's defaults. Baseline (pure Lua).
        utility.motion.flash-nvim.enable = true;

        # Autodetect shiftwidth/expandtab per buffer (baseline, pure Lua).
        utility.sleuth.enable = true;

        # More editing UX (baseline).
        ui.illuminate.enable = true; # highlight other uses of the word under cursor
        visuals.rainbow-delimiters.enable = true;

        # LSP $/progress (server startup, indexing) in the corner. Lazy on LspAttach,
        # full-tier only — baseline LSPs (nil/lua-ls) barely report progress.
        visuals.fidget-nvim.enable = full;
        notes.todo-comments = {
          enable = true;
          # No telescope/trouble here, so drop those binds; <leader>tdq (quickfix) stays.
          mappings = {
            telescope = null;
            trouble = null;
          };
        };

        tabline.nvimBufferline = {
          enable = true;
          setupOpts.options = {
            diagnostics = "nvim_lsp";
            show_close_icon = false;
            show_buffer_close_icons = false;
            separator_style = "thin";
            always_show_bufferline = true;
          };
        };

        git.gitsigns = {
          enable = true;
          setupOpts.signs = {
            add = {text = "│";};
            change = {text = "│";};
            delete = {text = "_";};
            topdelete = {text = "‾";};
            changedelete = {text = "~";};
          };
        };

        binds.whichKey.enable = true;

        mini = {
          pairs.enable = true;
          icons.enable = true;
          # gs* prefix so flash.nvim owns bare s/S (mini.surround defaults to an s prefix).
          surround = {
            enable = true;
            setupOpts.mappings = {
              add = "gsa";
              delete = "gsd";
              replace = "gsr";
              find = "gsf";
              find_left = "gsF";
              highlight = "gsh";
              update_n_lines = "gsn";
            };
          };
        };

        statusline.lualine = {
          enable = true;
          theme = "auto";
        };

        extraPackages = [pkgs.ripgrep pkgs.fd]; # snacks grep/files

        # Runs after plugin setup: mock nvim-web-devicons (nvf's mini.icons does
        # not, but bufferline/snacks expect it) and register buffer-local LSP
        # keymaps on attach — buffer-local keeps default K etc. in non-LSP buffers,
        # and carries the PyCharm-style aliases (F2 / Alt-CR / Ctrl-Q).
        luaConfigPost = ''
          if _G.MiniIcons then MiniIcons.mock_nvim_web_devicons() end

          vim.api.nvim_create_autocmd("LspAttach", {
            group = vim.api.nvim_create_augroup("user-lsp-attach", { clear = true }),
            callback = function(event)
              local map = function(keys, fn, desc, mode)
                vim.keymap.set(mode or "n", keys, fn, { buffer = event.buf, desc = "LSP: " .. desc })
              end
              map("gd", vim.lsp.buf.definition, "Go to definition")
              map("gr", vim.lsp.buf.references, "Go to references")
              map("gI", vim.lsp.buf.implementation, "Go to implementation")
              map("gD", vim.lsp.buf.declaration, "Go to declaration")
              map("<leader>D", vim.lsp.buf.type_definition, "Type definition")
              map("<leader>rn", vim.lsp.buf.rename, "Rename")
              map("<leader>ca", vim.lsp.buf.code_action, "Code action", { "n", "v" })
              map("K", vim.lsp.buf.hover, "Hover documentation")
              map("<F2>", vim.lsp.buf.rename, "Rename")
              map("<A-CR>", vim.lsp.buf.code_action, "Code action", { "n", "v" })
              map("<C-q>", vim.lsp.buf.hover, "Quick documentation")
              map("<leader>cd", vim.diagnostic.open_float, "Line diagnostics")
            end,
          })
        '';

        keymaps = [
          # Picker (snacks)
          {
            key = "<leader>ff";
            mode = "n";
            action = "function() Snacks.picker.files() end";
            lua = true;
            desc = "Find files";
          }
          {
            key = "<leader>fg";
            mode = "n";
            action = "function() Snacks.picker.grep() end";
            lua = true;
            desc = "Live grep";
          }
          {
            key = "<leader>fb";
            mode = "n";
            action = "function() Snacks.picker.buffers() end";
            lua = true;
            desc = "Find buffers";
          }
          {
            key = "<leader>fr";
            mode = "n";
            action = "function() Snacks.picker.recent() end";
            lua = true;
            desc = "Recent files";
          }
          {
            key = "<leader>fa";
            mode = "n";
            action = "function() Snacks.picker.commands() end";
            lua = true;
            desc = "Find action";
          }
          {
            key = "<leader>fs";
            mode = "n";
            action = "function() Snacks.picker.lsp_symbols() end";
            lua = true;
            desc = "Find symbol";
          }
          {
            key = "<leader>fS";
            mode = "n";
            action = "function() Snacks.picker.lsp_workspace_symbols() end";
            lua = true;
            desc = "Find workspace symbol";
          }
          {
            key = "<leader>fd";
            mode = "n";
            action = "function() Snacks.picker.diagnostics() end";
            lua = true;
            desc = "Find diagnostics";
          }
          {
            key = "<C-e>";
            mode = "n";
            action = "function() Snacks.picker.recent() end";
            lua = true;
            desc = "Recent files";
          }
          {
            key = "<C-S-f>";
            mode = "n";
            action = "function() Snacks.picker.grep() end";
            lua = true;
            desc = "Find in files";
          }

          # Explorer (snacks)
          {
            key = "<A-1>";
            mode = "n";
            action = "function() Snacks.explorer() end";
            lua = true;
            desc = "Toggle file tree";
          }
          {
            key = "<leader>e";
            mode = "n";
            action = "function() Snacks.explorer() end";
            lua = true;
            desc = "Toggle file tree";
          }

          # Buffers / tabs
          {
            key = "<S-l>";
            mode = "n";
            action = "<cmd>BufferLineCycleNext<cr>";
            desc = "Next tab";
          }
          {
            key = "<S-h>";
            mode = "n";
            action = "<cmd>BufferLineCyclePrev<cr>";
            desc = "Previous tab";
          }
          {
            key = "<leader>bd";
            mode = "n";
            action = "<cmd>bdelete<cr>";
            desc = "Close buffer";
          }

          # Git (gitsigns; command form is stable across versions)
          {
            key = "]h";
            mode = "n";
            action = "<cmd>Gitsigns next_hunk<cr>";
            desc = "Next hunk";
          }
          {
            key = "[h";
            mode = "n";
            action = "<cmd>Gitsigns prev_hunk<cr>";
            desc = "Previous hunk";
          }
          {
            key = "<leader>gp";
            mode = "n";
            action = "<cmd>Gitsigns preview_hunk<cr>";
            desc = "Preview hunk";
          }
          {
            key = "<leader>gr";
            mode = "n";
            action = "<cmd>Gitsigns reset_hunk<cr>";
            desc = "Reset hunk";
          }
          {
            key = "<leader>gb";
            mode = "n";
            action = "<cmd>Gitsigns blame_line<cr>";
            desc = "Blame line";
          }
          {
            key = "<leader>gB";
            mode = "n";
            action = ''function() require("gitsigns").blame_line({ full = true }) end'';
            lua = true;
            desc = "Blame line (full)";
          }
          {
            key = "<leader>gd";
            mode = "n";
            action = "<cmd>Gitsigns diffthis<cr>";
            desc = "Diff this";
          }
          {
            key = "<leader>gt";
            mode = "n";
            action = "<cmd>Gitsigns toggle_current_line_blame<cr>";
            desc = "Toggle line blame";
          }

          # PyCharm-style comment toggle
          {
            key = "<C-/>";
            mode = "n";
            action = "gcc";
            noremap = false;
            desc = "Toggle comment";
          }
          {
            key = "<C-/>";
            mode = "v";
            action = "gc";
            noremap = false;
            desc = "Toggle comment";
          }

          # Diagnostics (global; fire even with no LSP attached, mirroring ]h/[h hunks)
          {
            key = "]d";
            mode = "n";
            action = ''function() vim.diagnostic.jump({ count = 1, float = true }) end'';
            lua = true;
            desc = "Next diagnostic";
          }
          {
            key = "[d";
            mode = "n";
            action = ''function() vim.diagnostic.jump({ count = -1, float = true }) end'';
            lua = true;
            desc = "Previous diagnostic";
          }

          # Clear search highlight (hlsearch is on; it otherwise lingers)
          {
            key = "<Esc>";
            mode = "n";
            action = "<cmd>nohlsearch<cr>";
            desc = "Clear search highlight";
          }

          # Save (GUI reflex; flash's <c-s> is command-mode only, no clash)
          {
            key = "<C-s>";
            mode = ["n" "v"];
            action = "<cmd>write<cr>";
            desc = "Save file";
          }
          {
            key = "<C-s>";
            mode = "i";
            action = "<cmd>write<cr>";
            desc = "Save file";
          }

          # Visual-mode QoL: keep selection on indent; move lines with J/K
          {
            key = "<";
            mode = "v";
            action = "<gv";
            desc = "Indent left, keep selection";
          }
          {
            key = ">";
            mode = "v";
            action = ">gv";
            desc = "Indent right, keep selection";
          }
          {
            key = "J";
            mode = "v";
            action = ":m '>+1<cr>gv=gv";
            desc = "Move selection down";
          }
          {
            key = "K";
            mode = "v";
            action = ":m '<-2<cr>gv=gv";
            desc = "Move selection up";
          }

          # <C-_> fallback for the <C-/> comment toggle (many terminals send 0x1f)
          {
            key = "<C-_>";
            mode = "n";
            action = "gcc";
            noremap = false;
            desc = "Toggle comment";
          }
          {
            key = "<C-_>";
            mode = "v";
            action = "gc";
            noremap = false;
            desc = "Toggle comment";
          }

          # Format
          {
            key = "<leader>cf";
            mode = ["n" "v"];
            action = ''function() require("conform").format({ async = true, lsp_format = "fallback" }) end'';
            lua = true;
            desc = "Format buffer";
          }
        ];
      };
    };
  };
}
