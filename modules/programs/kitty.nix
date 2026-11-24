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
    # Ghostty-style search overlay; a selection prefills it.
    search = lib.concatStringsSep " " [
      "kitten ${./kitty-search.py}"
      "match_fg=${c.black} match_bg=${c.yellow} current_fg=${c.black} current_bg=${c.orange}"
      "box_fg=${c.fg} box_muted=${c.muted} field_bg=${c.ui} error=${c.red}"
      "@selection"
    ];
    searchKey =
      if pkgs.stdenv.isDarwin
      then "cmd+f"
      else "kitty_mod+f";
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
            window_padding_width = 4;
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
            # Replaces kitty's default (move_window_forward; search_scrollback on macOS).
            ${searchKey} = search;
          }
          // lib.optionalAttrs pkgs.stdenv.isDarwin {
            "cmd+n" = "launch --type=os-window --cwd=current";
          };
        # Inside the search overlay the key goes to the kitten (re-selecting its
        # text, like Ghostty) instead of stacking a second search on top.
        extraConfig = ''
          map --when-focus-on var:kitty_search ${searchKey}
        '';
      };
    };
  };
}
