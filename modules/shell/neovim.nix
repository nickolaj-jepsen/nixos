_: {
  config = {
    programs.neovim = {
      enable = true;
      vimAlias = true;
      defaultEditor = true;
    };

    programs.nvf = {
      enable = true;

      settings.vim = {
        viAlias = true;
        vimAlias = true;

        lineNumberMode = "number";

        lsp = {
          enable = true;
          lightbulb.enable = true;
        };

        languages = {
          enableLSP = true;
          enableFormat = true;
          enableTreesitter = true;

          nix.enable = true;
          markdown.enable = true;
          rust.enable = true;
          sql.enable = true;
          ts.enable = true;
          html.enable = true;
          python.enable = true;
        };

        git.enable = true;

        telescope.enable = true;
        autopairs.nvim-autopairs.enable = true;
        autocomplete.blink-cmp.enable = true;
        statusline.lualine.enable = true;

        utility = {
          ccc.enable = false;
          vim-wakatime.enable = false;
          icon-picker.enable = false;
          motion.leap.enable = true;
        };
        ui = {
          borders.enable = true;
          colorizer.enable = true;
        };

        binds = {
          whichKey.enable = true;
        };
      };
    };
  };
}
