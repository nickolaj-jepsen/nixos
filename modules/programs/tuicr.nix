# tuicr: a code-review TUI whose comments agents read back through its skill.
{
  flake.modules.homeManager.tuicr = {
    config,
    lib,
    pkgs,
    ...
  }: let
    c = config.fireproof.theme.colors;
    toml = pkgs.formats.toml {};
    hex = name: "#${c.${name}}";
    # tuicr colors are opaque #RRGGBB, so diff backgrounds are pre-mixed over bg.
    tint = name: let
      channel = color: i: lib.fromHexString (builtins.substring i 2 color);
      mix = i: (channel c.bg i * 80 + channel c.${name} i * 20) / 100;
      pad = n: lib.fixedWidthString 2 "0" (lib.toHexString n);
    in "#${lib.concatMapStrings (i: pad (mix i)) [0 2 4]}";
  in {
    config = lib.mkIf config.fireproof.dev.enable {
      # dtach keeps the review alive while pi's TUI is suspended in front of it.
      home.packages = [pkgs.unstable.tuicr pkgs.dtach];

      # Same tarball trick as gh-stack in git.nix: the skill matches the installed version.
      fireproof.agents.skills.tuicr = let
        inherit (pkgs.unstable.tuicr) src;
      in "${builtins.fetchTarball {
        inherit (src) url;
        sha256 = src.outputHash;
      }}/skills/tuicr";

      xdg.configFile."tuicr/config.toml".source = toml.generate "tuicr-config.toml" {
        theme = "fireproof";
        compact_folders = true;
        q_quits = true; # like less and gh-dash, and what the skill tells agents
        scroll_offset = 10; # matches neovim's scrolloff
        wrap = true;
        wrap_style = "gutter";
        diff_watch_interval_ms = 2000; # follow an agent's uncommitted edits live
        show_pr_checks = true;
        no_update_check = true; # nix owns the version
        username = "Nickolaj";
        # Colleagues read submitted comments; the type matters to agents, which read them locally.
        forge.comment_type_prefix = false;
        # The tuicr skill's ids, plus nit; each definition reaches the agent in the review's legend.
        comment_types = [
          {
            id = "issue";
            definition = "must fix";
            color = hex "red";
          }
          {
            id = "suggestion";
            definition = "consider it, or explain why not";
            color = hex "cyan";
          }
          {
            id = "nit";
            definition = "optional polish, take it or leave it";
            color = hex "yellow";
          }
          {
            id = "note";
            label = "question";
            definition = "answer or acknowledge";
            color = hex "blue";
          }
          {
            id = "praise";
            definition = "no action needed";
            color = hex "green";
          }
        ];
      };

      xdg.configFile."tuicr/themes/fireproof.toml".source = toml.generate "tuicr-fireproof.toml" {
        panel_bg = hex "bg";
        bg_highlight = hex "ui";
        fg_primary = hex "fg";
        fg_secondary = hex "fgAlt";
        fg_dim = hex "muted";

        diff_add = hex "green";
        diff_add_bg = tint "green";
        diff_del = hex "red";
        diff_del_bg = tint "red";
        diff_context = hex "fg";
        diff_hunk_header = hex "cyan";
        expanded_context_fg = hex "muted";
        syntax_add_bg = tint "green";
        syntax_del_bg = tint "red";

        file_added = hex "green";
        file_modified = hex "yellow";
        file_deleted = hex "red";
        file_renamed = hex "purple";
        reviewed = hex "green";
        pending = hex "yellow";

        comment_note = hex "blue";
        comment_suggestion = hex "cyan";
        comment_issue = hex "red";
        comment_praise = hex "green";

        border_focused = hex "accent";
        border_unfocused = hex "uiAlt";
        status_bar_bg = hex "bgAlt";
        cursor_color = hex "accent";
        cursor_line_bg = hex "bgAlt";
        branch_name = hex "purple";
        help_indicator = hex "muted";

        message_info_fg = hex "black";
        message_info_bg = hex "blue";
        message_warning_fg = hex "black";
        message_warning_bg = hex "orange";
        message_error_fg = hex "black";
        message_error_bg = hex "red";
        update_badge_fg = hex "black";
        update_badge_bg = hex "yellow";
        mode_fg = hex "black";
        mode_bg = hex "accent";
      };
    };
  };
}
