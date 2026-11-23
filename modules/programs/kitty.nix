{fpLib, ...}: {
  flake.modules.darwin.kitty = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf config.fireproof.desktop.enable {
      homebrew.casks = ["kitty"];
    };
  };

  flake.modules.homeManager.kitty = {
    config,
    lib,
    pkgs,
    ...
  }: let
    c = config.fireproof.theme.colors;
    # Mirrors themes.fireproof in the ghostty leaf; keep the two in sync.
    palette = with c; [black redAlt greenAlt yellowAlt blueAlt magentaAlt cyanAlt fg muted red green yellow blue magenta cyan whiteAlt];
  in {
    config = lib.mkIf config.fireproof.desktop.enable {
      home.sessionVariables.TERMINAL = "kitty";
      programs.kitty = {
        enable = true;
        package = fpLib.mkDarwinGuiPackage pkgs pkgs.unstable.kitty;
        settings =
          {
            font_family = config.fireproof.theme.font.family;
            font_size =
              if pkgs.stdenv.isDarwin
              then 14
              else 11;
            hide_window_decorations = !pkgs.stdenv.isDarwin;
            # Ghostty's window-padding-color=extend has no kitty equivalent: deliberate
            # padding is always drawn in `background`, so a TUI's own bg would leave a
            # frame. Drop it and let the leftover strips take the neighbouring cell's colour.
            window_padding_width = 0;
            padding_fill_strategy = "neighboring_cell";
            background_opacity = 0.9;
            background_blur = 20;
            mouse_hide_wait = -1;
            copy_on_select = false;
            notify_on_cmd_finish = "unfocused 30 bell";
            # Kitty measures live scrollback in lines; only the pager limit is in MiB.
            scrollback_lines = 10000;
            scrollback_pager_history_size = 100;
            update_check_interval = 0;
            background = "#${c.bg}";
            foreground = "#${c.fg}";
            cursor = "#${c.fg}";
            selection_background = "#${c.uiAlt}";
            selection_foreground = "#${c.fg}";
          }
          // builtins.listToAttrs (lib.imap0 (i: color: lib.nameValuePair "color${toString i}" "#${color}") palette);
        keybindings =
          {
            "ctrl+shift+c" = "copy_to_clipboard";
            "ctrl+shift+v" = "paste_from_clipboard";
            "ctrl+enter" = "no_op";
            # The compositor opens a fresh terminal; Kitty knows the pane's cwd.
            "kitty_mod+n" = "launch --type=os-window --cwd=current";
            # Replaces the default move_window_forward.
            "kitty_mod+f" = "kitten ${./kitty-search.py}";
          }
          // lib.optionalAttrs pkgs.stdenv.isDarwin {
            "cmd+n" = "launch --type=os-window --cwd=current";
          };
      };
    };
  };
}
