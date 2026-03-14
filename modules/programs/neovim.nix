{pkgs, ...}: {
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
      tree-sitter # for treesitter
    ];

    extraLuaConfig = ''
      -- General settings
      vim.g.mapleader = " "
      vim.g.maplocalleader = " "

      vim.opt.number = true
      vim.opt.mouse = "a"
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

      -- PyCharm-style comment toggle (Ctrl+/)
      vim.keymap.set("n", "<C-/>", "gcc", { remap = true, desc = "Toggle comment" })
      vim.keymap.set("v", "<C-/>", "gc", { remap = true, desc = "Toggle comment" })

      -- Built-in colorscheme
      vim.cmd.colorscheme("habamax")
    '';

    plugins = with pkgs.vimPlugins; [
      # Treesitter for syntax highlighting
      {
        plugin = nvim-treesitter.withPlugins (p:
          with p; [
            nix
            bash
            fish
            lua
            python
            javascript
            typescript
            tsx
            json
            yaml
            toml
            markdown
            markdown_inline
            html
            css
            dockerfile
            git_config
            gitcommit
            gitignore
            regex
            vim
            vimdoc
          ]);
        type = "lua";
        config = ''
          require("nvim-treesitter.configs").setup({
            highlight = { enable = true },
            indent = { enable = true },
          })
        '';
      }

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
          vim.keymap.set("n", "<leader>fr", builtin.oldfiles, { desc = "Recent files" })
          vim.keymap.set("n", "<leader>fa", builtin.commands, { desc = "Find action" })
          vim.keymap.set("n", "<leader>fs", builtin.lsp_document_symbols, { desc = "Find symbol" })
          vim.keymap.set("n", "<leader>fS", builtin.lsp_dynamic_workspace_symbols, { desc = "Find workspace symbol" })
          vim.keymap.set("n", "<leader>fd", builtin.diagnostics, { desc = "Find diagnostics" })

          -- PyCharm-style keybinds
          vim.keymap.set("n", "<C-e>", builtin.oldfiles, { desc = "Recent files" })
          vim.keymap.set("n", "<C-S-f>", builtin.live_grep, { desc = "Find in files" })
        '';
      }
      telescope-fzf-native-nvim
      plenary-nvim

      # Project sidebar
      {
        plugin = neo-tree-nvim;
        type = "lua";
        config = ''
          require("neo-tree").setup({
            close_if_last_window = true,
            filesystem = {
              follow_current_file = { enabled = true },
              use_libuv_file_watcher = true,
              filtered_items = {
                hide_dotfiles = false,
                hide_gitignored = true,
              },
            },
            window = {
              width = 35,
              mappings = {
                ["<space>"] = "none",
              },
            },
          })
          vim.keymap.set("n", "<A-1>", "<cmd>Neotree toggle<cr>", { desc = "Toggle file tree" })
          vim.keymap.set("n", "<leader>e", "<cmd>Neotree toggle<cr>", { desc = "Toggle file tree" })
        '';
      }
      nvim-web-devicons
      nui-nvim

      # Tab bar
      {
        plugin = bufferline-nvim;
        type = "lua";
        config = ''
          require("bufferline").setup({
            options = {
              diagnostics = "nvim_lsp",
              show_close_icon = false,
              show_buffer_close_icons = false,
              separator_style = "thin",
              always_show_bufferline = true,
              offsets = {
                { filetype = "neo-tree", text = "File Explorer", highlight = "Directory", separator = true },
              },
            },
          })
          vim.keymap.set("n", "<S-l>", "<cmd>BufferLineCycleNext<cr>", { desc = "Next tab" })
          vim.keymap.set("n", "<S-h>", "<cmd>BufferLineCyclePrev<cr>", { desc = "Previous tab" })
          vim.keymap.set("n", "<leader>bd", "<cmd>bdelete<cr>", { desc = "Close buffer" })
          vim.keymap.set("n", "<C-w>", "<cmd>bdelete<cr>", { desc = "Close buffer" })
        '';
      }

      # Git gutter + blame
      {
        plugin = gitsigns-nvim;
        type = "lua";
        config = ''
          require("gitsigns").setup({
            signs = {
              add = { text = "│" },
              change = { text = "│" },
              delete = { text = "_" },
              topdelete = { text = "‾" },
              changedelete = { text = "~" },
            },
            on_attach = function(bufnr)
              local gs = package.loaded.gitsigns
              local map = function(mode, l, r, desc)
                vim.keymap.set(mode, l, r, { buffer = bufnr, desc = desc })
              end
              map("n", "]h", gs.next_hunk, "Next hunk")
              map("n", "[h", gs.prev_hunk, "Previous hunk")
              map("n", "<leader>gp", gs.preview_hunk, "Preview hunk")
              map("n", "<leader>gr", gs.reset_hunk, "Reset hunk")
              map("n", "<leader>gb", gs.blame_line, "Blame line")
              map("n", "<leader>gB", function() gs.blame_line({ full = true }) end, "Blame line (full)")
              map("n", "<leader>gd", gs.diffthis, "Diff this")
              map("n", "<leader>gt", gs.toggle_current_line_blame, "Toggle line blame")
            end,
          })
        '';
      }

      # Auto bracket pairs
      {
        plugin = nvim-autopairs;
        type = "lua";
        config = ''
          require("nvim-autopairs").setup({})
          local cmp_autopairs = require("nvim-autopairs.completion.cmp")
          local cmp = require("cmp")
          cmp.event:on("confirm_done", cmp_autopairs.on_confirm_done())
        '';
      }

      # Surround editing
      {
        plugin = nvim-surround;
        type = "lua";
        config = ''
          require("nvim-surround").setup({})
        '';
      }

      # Key hint popup
      {
        plugin = which-key-nvim;
        type = "lua";
        config = ''
          local wk = require("which-key")
          wk.setup({
            delay = 300,
          })
          wk.add({
            { "<leader>f", group = "Find" },
            { "<leader>g", group = "Git" },
            { "<leader>b", group = "Buffer" },
            { "<leader>c", group = "Code" },
            { "<leader>r", group = "Refactor" },
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

              -- PyCharm-style LSP keybinds
              map("<F2>", vim.lsp.buf.rename, "Rename")
              map("<A-CR>", vim.lsp.buf.code_action, "Code action")
              map("<C-q>", vim.lsp.buf.hover, "Quick documentation")
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

          cmp.setup({
            completion = { completeopt = "menu,menuone,noinsert" },
            mapping = cmp.mapping.preset.insert({
              ["<C-n>"] = cmp.mapping.select_next_item(),
              ["<C-p>"] = cmp.mapping.select_prev_item(),
              ["<C-b>"] = cmp.mapping.scroll_docs(-4),
              ["<C-f>"] = cmp.mapping.scroll_docs(4),
              ["<C-y>"] = cmp.mapping.confirm({ select = true }),
              ["<C-Space>"] = cmp.mapping.complete({}),
            }),
            sources = {
              { name = "nvim_lsp" },
              { name = "buffer" },
              { name = "path" },
            },
          })
        '';
      }
      cmp-nvim-lsp
      cmp-buffer
      cmp-path

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
    ];
  };
}
