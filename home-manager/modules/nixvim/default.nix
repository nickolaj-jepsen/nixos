{ inputs, ... }:
{
  imports = [
    inputs.nixvim.homeManagerModules.nixvim
  ];

  programs.neovim = {
    defaultEditor = true;
  };

  programs.nixvim = {
    enable = true;
    
    opts = {
      number = true;
      relativenumber = false;
      tabstop = 4;
      shiftwidth = 4;
      expandtab = false;
    };

    globals.mapleader = " ";

    keymaps = [
      {
        key = "jk";
        action = "<ESC>";
        mode = "i";
      }
      {
        key = "<leader>o";
        action = ":NvimTreeToggle<CR>";
        options = {
          silent = true;
        };
      }
    ];

    colorschemes.base16 = {
      enable = true;
      colorscheme = "twilight";
    };

    plugins = {
      barbecue.enable = true;
      nvim-colorizer.enable = true;
      gitsigns.enable = true;
      indent-blankline.enable = true;
      surround.enable = true;
      bufferline.enable = true;
      nvim-autopairs.enable = true;
      lsp-format.enable = true;
      lightline.enable = true;
      intellitab.enable = true;
      which-key.enable = true;
      
      telescope = {
        enable = true;
        keymaps = {
          "<leader>ff" = "find_files";
        };
      };

      nvim-tree = {
        enable = true;
        filters.custom = [
          ".git"
        ];
      };

      treesitter = {
        enable = true;
        nixGrammars = true;
      };

      lsp = {
        enable = true;
        servers.nil-ls.enable = true;
      };

      lspkind = {
        enable = true;
      };

      cmp = {
        enable = true;
      };
    };
  };
}