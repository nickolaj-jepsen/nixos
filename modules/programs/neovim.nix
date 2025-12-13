{pkgs, ...}: let
  darcula-nvim = pkgs.vimUtils.buildVimPlugin {
    pname = "darcula";
    version = "2024-10-01";
    src = pkgs.fetchFromGitHub {
      owner = "doums";
      repo = "darcula";
      rev = "faf8dbab27bee0f27e4f1c3ca7e9695af9b1242b";
      sha256 = "sha256-Gn+lmlYxSIr91Bg3fth2GAQou2Nd1UjrLkIFbBYlmF8=";
    };
  };
in {
  fireproof.home-manager.programs.neovim = {
    enable = true;
    vimAlias = true;
    viAlias = true;
    defaultEditor = true;

    extraPackages = with pkgs; [
      # LSP servers
      nil # Nix
      basedpyright # Python
      nodePackages.typescript-language-server
      vscode-langservers-extracted # HTML, CSS, JSON, ESLint
      lua-language-server
      marksman # Markdown
      yaml-language-server

      # Formatters & linters
      alejandra # Nix formatter
      stylua # Lua formatter
      nodePackages.prettier
      ruff # Python linter/formatter

      # Tools for plugins
      ripgrep # for telescope
      fd # for telescope
      lazygit # for lazygit.nvim
      tree-sitter # for treesitter
    ];

    extraLuaConfig = ''
      -- General settings
      vim.g.mapleader = " "
      vim.g.maplocalleader = " "

      vim.opt.number = true
      vim.opt.mouse = "a"
      vim.opt.showmode = false
      vim.opt.clipboard = "unnamedplus"
      vim.opt.breakindent = true
      vim.opt.undofile = true
      vim.opt.ignorecase = true
      vim.opt.smartcase = true
      vim.opt.signcolumn = "yes"
      vim.opt.updatetime = 250
      vim.opt.timeoutlen = 300
      vim.opt.splitright = true
      vim.opt.splitbelow = true
      vim.opt.list = true
      vim.opt.listchars = { tab = "» ", trail = "·", nbsp = "␣" }
      vim.opt.inccommand = "split"
      vim.opt.cursorline = true
      vim.opt.scrolloff = 10
      vim.opt.hlsearch = true
      vim.opt.termguicolors = true
      vim.opt.tabstop = 2
      vim.opt.shiftwidth = 2
      vim.opt.expandtab = true

      -- Clear search highlight on pressing <Esc>
      vim.keymap.set("n", "<Esc>", "<cmd>nohlsearch<CR>")

      -- Diagnostic keymaps
      vim.keymap.set("n", "[d", vim.diagnostic.goto_prev, { desc = "Go to previous diagnostic" })
      vim.keymap.set("n", "]d", vim.diagnostic.goto_next, { desc = "Go to next diagnostic" })
      vim.keymap.set("n", "<leader>e", vim.diagnostic.open_float, { desc = "Show diagnostic error" })
      vim.keymap.set("n", "<leader>q", vim.diagnostic.setloclist, { desc = "Open diagnostic quickfix" })

      -- Window navigation
      vim.keymap.set("n", "<C-h>", "<C-w><C-h>", { desc = "Move to left window" })
      vim.keymap.set("n", "<C-l>", "<C-w><C-l>", { desc = "Move to right window" })
      vim.keymap.set("n", "<C-j>", "<C-w><C-j>", { desc = "Move to lower window" })
      vim.keymap.set("n", "<C-k>", "<C-w><C-k>", { desc = "Move to upper window" })

      -- Better indenting
      vim.keymap.set("v", "<", "<gv")
      vim.keymap.set("v", ">", ">gv")
    '';

    plugins = with pkgs.vimPlugins; [
      # Colorscheme (JetBrains/Darcula theme)
      {
        plugin = darcula-nvim;
        type = "lua";
        config = ''
          vim.cmd.colorscheme("darcula")
        '';
      }

      # File explorer
      {
        plugin = neo-tree-nvim;
        type = "lua";
        config = ''
          require("neo-tree").setup({
            filesystem = {
              follow_current_file = { enabled = true },
              hijack_netrw_behavior = "open_current",
            },
          })
          vim.keymap.set("n", "<leader>e", "<cmd>Neotree toggle<CR>", { desc = "Toggle file explorer" })
        '';
      }
      nvim-web-devicons
      plenary-nvim

      # Fuzzy finder
      {
        plugin = telescope-nvim;
        type = "lua";
        config = ''
          local telescope = require("telescope")
          local builtin = require("telescope.builtin")
          telescope.setup({
            defaults = {
              file_ignore_patterns = { "node_modules", ".git/", "__pycache__" },
            },
          })
          vim.keymap.set("n", "<leader>ff", builtin.find_files, { desc = "Find files" })
          vim.keymap.set("n", "<leader>fg", builtin.live_grep, { desc = "Live grep" })
          vim.keymap.set("n", "<leader>fb", builtin.buffers, { desc = "Find buffers" })
          vim.keymap.set("n", "<leader>fh", builtin.help_tags, { desc = "Help tags" })
          vim.keymap.set("n", "<leader>fr", builtin.oldfiles, { desc = "Recent files" })
          vim.keymap.set("n", "<leader>fd", builtin.diagnostics, { desc = "Diagnostics" })
          vim.keymap.set("n", "<leader>fs", builtin.lsp_document_symbols, { desc = "Document symbols" })
        '';
      }
      telescope-fzf-native-nvim

      # Treesitter for syntax highlighting
      {
        plugin = nvim-treesitter.withAllGrammars;
        type = "lua";
        config = ''
          require("nvim-treesitter.configs").setup({
            highlight = { enable = true },
            indent = { enable = true },
            incremental_selection = {
              enable = true,
              keymaps = {
                init_selection = "<C-space>",
                node_incremental = "<C-space>",
                scope_incremental = false,
                node_decremental = "<bs>",
              },
            },
          })
        '';
      }

      # LSP
      {
        plugin = nvim-lspconfig;
        type = "lua";
        config = ''
          -- LSP keymaps on attach
          vim.api.nvim_create_autocmd("LspAttach", {
            group = vim.api.nvim_create_augroup("lsp-attach", { clear = true }),
            callback = function(event)
              local map = function(keys, func, desc)
                vim.keymap.set("n", keys, func, { buffer = event.buf, desc = "LSP: " .. desc })
              end
              map("gd", vim.lsp.buf.definition, "Go to definition")
              map("gr", vim.lsp.buf.references, "Go to references")
              map("gI", vim.lsp.buf.implementation, "Go to implementation")
              map("<leader>D", vim.lsp.buf.type_definition, "Type definition")
              map("<leader>rn", vim.lsp.buf.rename, "Rename")
              map("<leader>ca", vim.lsp.buf.code_action, "Code action")
              map("K", vim.lsp.buf.hover, "Hover documentation")
              map("gD", vim.lsp.buf.declaration, "Go to declaration")
            end,
          })

          -- Configure LSP servers using vim.lsp.config (Neovim 0.11+)
          vim.lsp.config("nil_ls", {})
          vim.lsp.config("basedpyright", {})
          vim.lsp.config("ts_ls", {})
          vim.lsp.config("lua_ls", {
            settings = {
              Lua = {
                runtime = { version = "LuaJIT" },
                diagnostics = { globals = { "vim" } },
              },
            },
          })
          vim.lsp.config("jsonls", {})
          vim.lsp.config("yamlls", {})
          vim.lsp.config("marksman", {})

          -- Enable the configured LSP servers
          vim.lsp.enable({ "nil_ls", "basedpyright", "ts_ls", "lua_ls", "jsonls", "yamlls", "marksman" })
        '';
      }

      # Autocompletion
      {
        plugin = nvim-cmp;
        type = "lua";
        config = ''
          local cmp = require("cmp")
          local luasnip = require("luasnip")
          luasnip.config.setup({})

          cmp.setup({
            snippet = {
              expand = function(args)
                luasnip.lsp_expand(args.body)
              end,
            },
            completion = { completeopt = "menu,menuone,noinsert" },
            mapping = cmp.mapping.preset.insert({
              ["<C-n>"] = cmp.mapping.select_next_item(),
              ["<C-p>"] = cmp.mapping.select_prev_item(),
              ["<C-b>"] = cmp.mapping.scroll_docs(-4),
              ["<C-f>"] = cmp.mapping.scroll_docs(4),
              ["<C-y>"] = cmp.mapping.confirm({ select = true }),
              ["<C-Space>"] = cmp.mapping.complete({}),
              ["<Tab>"] = cmp.mapping(function(fallback)
                if cmp.visible() then
                  cmp.select_next_item()
                elseif luasnip.expand_or_locally_jumpable() then
                  luasnip.expand_or_jump()
                else
                  fallback()
                end
              end, { "i", "s" }),
              ["<S-Tab>"] = cmp.mapping(function(fallback)
                if cmp.visible() then
                  cmp.select_prev_item()
                elseif luasnip.locally_jumpable(-1) then
                  luasnip.jump(-1)
                else
                  fallback()
                end
              end, { "i", "s" }),
            }),
            sources = {
              { name = "nvim_lsp" },
              { name = "luasnip" },
              { name = "buffer" },
              { name = "path" },
            },
          })
        '';
      }
      cmp-nvim-lsp
      cmp-buffer
      cmp-path
      luasnip
      cmp_luasnip
      friendly-snippets

      # Formatting
      {
        plugin = conform-nvim;
        type = "lua";
        config = ''
          require("conform").setup({
            formatters_by_ft = {
              lua = { "stylua" },
              python = { "ruff_format" },
              javascript = { "prettier" },
              typescript = { "prettier" },
              javascriptreact = { "prettier" },
              typescriptreact = { "prettier" },
              json = { "prettier" },
              yaml = { "prettier" },
              markdown = { "prettier" },
              html = { "prettier" },
              css = { "prettier" },
              nix = { "alejandra" },
            },
            format_on_save = {
              timeout_ms = 500,
              lsp_fallback = true,
            },
          })
          vim.keymap.set({ "n", "v" }, "<leader>cf", function()
            require("conform").format({ async = true, lsp_fallback = true })
          end, { desc = "Format buffer" })
        '';
      }

      # Git integration
      {
        plugin = gitsigns-nvim;
        type = "lua";
        config = ''
          require("gitsigns").setup({
            signs = {
              add = { text = "▎" },
              change = { text = "▎" },
              delete = { text = "" },
              topdelete = { text = "" },
              changedelete = { text = "▎" },
            },
            on_attach = function(bufnr)
              local gs = package.loaded.gitsigns
              local function map(mode, l, r, opts)
                opts = opts or {}
                opts.buffer = bufnr
                vim.keymap.set(mode, l, r, opts)
              end
              map("n", "]c", gs.next_hunk, { desc = "Next git hunk" })
              map("n", "[c", gs.prev_hunk, { desc = "Previous git hunk" })
              map("n", "<leader>hs", gs.stage_hunk, { desc = "Stage hunk" })
              map("n", "<leader>hr", gs.reset_hunk, { desc = "Reset hunk" })
              map("n", "<leader>hb", gs.blame_line, { desc = "Blame line" })
              map("n", "<leader>hp", gs.preview_hunk, { desc = "Preview hunk" })
            end,
          })
        '';
      }

      {
        plugin = lazygit-nvim;
        type = "lua";
        config = ''
          vim.keymap.set("n", "<leader>gg", "<cmd>LazyGit<CR>", { desc = "Open LazyGit" })
        '';
      }

      # UI improvements
      {
        plugin = lualine-nvim;
        type = "lua";
        config = ''
          require("lualine").setup({
            options = {
              theme = "auto",
              component_separators = { left = "", right = "" },
              section_separators = { left = "", right = "" },
            },
          })
        '';
      }

      {
        plugin = indent-blankline-nvim;
        type = "lua";
        config = ''
          require("ibl").setup({
            indent = { char = "│" },
            scope = { enabled = true },
          })
        '';
      }

      {
        plugin = which-key-nvim;
        type = "lua";
        config = ''
          require("which-key").setup({})
          require("which-key").add({
            { "<leader>f", group = "Find" },
            { "<leader>c", group = "Code" },
            { "<leader>h", group = "Git Hunk" },
            { "<leader>g", group = "Git" },
          })
        '';
      }

      # Autopairs
      {
        plugin = nvim-autopairs;
        type = "lua";
        config = ''
          require("nvim-autopairs").setup({})
        '';
      }

      # Comments
      {
        plugin = comment-nvim;
        type = "lua";
        config = ''
          require("Comment").setup({})
        '';
      }

      # Surround
      {
        plugin = nvim-surround;
        type = "lua";
        config = ''
          require("nvim-surround").setup({})
        '';
      }
    ];
  };
}
