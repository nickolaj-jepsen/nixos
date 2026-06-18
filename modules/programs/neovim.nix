# neovim via nvf. Always-on lean baseline (editing UX + nil/lua-ls + cheap
# grammars) on every host; the heavy language support layers on only when
# fireproof.neovim.full.enable (defaults to dev.enable, off on the phone) — see
# docs/phone-aarch64-cache.md.
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

        languages = {
          enableTreesitter = true;
          enableFormat = true;

          # Baseline (every host, incl. phone).
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

        # Baseline grammars for cheap, phone-relevant filetypes that have no
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

        autocomplete.blink-cmp = {
          enable = true;
          friendly-snippets.enable = true;
          setupOpts = {
            keymap.preset = "default";
            appearance.nerd_font_variant = "normal";
            sources.default = ["lsp" "path" "snippets" "buffer"];
            signature.enabled = true;
            completion.documentation = {
              auto_show = true;
              auto_show_delay_ms = 200;
            };
          };
        };

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
          surround.enable = true;
          icons.enable = true;
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
          {
            key = "<C-w>";
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

          # Format
          {
            key = "<leader>cf";
            mode = ["n" "v"];
            action = ''function() require("conform").format({ async = true, lsp_fallback = true }) end'';
            lua = true;
            desc = "Format buffer";
          }
        ];
      };
    };
  };
}
