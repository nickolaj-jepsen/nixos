{
  config,
  lib,
  ...
}: let
  c = config.fireproof.theme.colors;
  hex = name: "#${c.${name}}";
  hexA = name: alpha: "#${c.${name}}${alpha}";
in {
  config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.dev.enable) {
    fireproof.home-manager.programs.zed-editor = {
      userSettings.theme = "Flexoki Fireproof";

      themes."flexoki-fireproof" = {
        "$schema" = "https://zed.dev/schema/themes/v0.2.0.json";
        name = "Flexoki Fireproof";
        author = "fireproof";
        themes = [
          {
            name = "Flexoki Fireproof";
            appearance = "dark";
            style = {
              # Core — UI text uses a near-white tone (à la VSCode), while editor
              # content keeps the warmer `fg` cream via `editor.foreground` below.
              background = hex "bg";
              "background.appearance" = "opaque";
              text = "#dedede";
              "text.muted" = hex "muted";
              "text.placeholder" = hex "muted";
              "text.disabled" = hex "muted";
              "text.accent" = hex "accent";

              # Borders
              border = hex "ui";
              "border.variant" = hex "ui";
              "border.focused" = hexA "accent" "88";
              "border.selected" = hex "accent";
              "border.transparent" = "#00000000";
              "border.disabled" = hex "ui";

              # Surfaces
              "surface.background" = hex "bg";
              "elevated_surface.background" = hex "bgAlt";

              # Panels and bars (mirrors VSCode workbench colors)
              "panel.background" = hex "bg";
              "panel.focused_border" = hex "accent";
              "panel.indent_guide" = hex "ui";
              "panel.indent_guide_active" = hex "uiAlt";
              "panel.indent_guide_hover" = hex "uiAlt";
              "pane.focused_border" = hex "accent";
              "pane_group.border" = hex "ui";

              "title_bar.background" = hex "bg";
              "title_bar.inactive_background" = hex "bg";
              "toolbar.background" = hex "bg";

              # Status bar — keep dark like the rest of the UI so icons stay readable
              "status_bar.background" = hex "bg";

              # Tab bar
              "tab_bar.background" = hex "bg";
              "tab.active_background" = hex "bgAlt";
              "tab.inactive_background" = hex "bg";

              # Editor
              "editor.background" = hex "bg";
              "editor.foreground" = hex "fg";
              "editor.gutter.background" = hex "bg";
              "editor.line_number" = hex "muted";
              "editor.active_line_number" = hex "fg";
              "editor.active_line.background" = hex "bgAlt";
              "editor.highlighted_line.background" = hex "bgAlt";
              "editor.indent_guide" = hex "ui";
              "editor.indent_guide_active" = hex "uiAlt";
              "editor.wrap_guide" = hex "ui";
              "editor.active_wrap_guide" = hex "uiAlt";
              "editor.invisible" = hex "ui";
              "editor.subheader.background" = hex "bgAlt";
              "editor.document_highlight.bracket_background" = hexA "accent" "44";
              "editor.document_highlight.read_background" = hexA "accent" "22";
              "editor.document_highlight.write_background" = hexA "orange" "33";

              # Element states (lists, menus, hover)
              "element.background" = hex "bg";
              "element.hover" = hex "bgAlt";
              "element.active" = hex "uiAlt";
              "element.selected" = hex "uiAlt";
              "element.disabled" = hex "ui";
              "ghost_element.background" = "#00000000";
              "ghost_element.hover" = hex "bgAlt";
              "ghost_element.active" = hex "uiAlt";
              "ghost_element.selected" = hex "uiAlt";
              "ghost_element.disabled" = hex "ui";

              # Drop targets, search
              "drop_target.background" = hexA "accent" "33";
              "search.match_background" = hexA "accent" "44";
              "link_text.hover" = hex "blue";

              # Icons
              icon = "#dedede";
              "icon.muted" = hex "muted";
              "icon.disabled" = hex "muted";
              "icon.placeholder" = hex "muted";
              "icon.accent" = hex "accent";

              # Status indicators
              error = hex "red";
              "error.background" = hexA "red" "22";
              "error.border" = hex "red";
              warning = hex "yellow";
              "warning.background" = hexA "yellow" "22";
              "warning.border" = hex "yellow";
              success = hex "green";
              "success.background" = hexA "green" "22";
              "success.border" = hex "green";
              info = hex "blue";
              "info.background" = hexA "blue" "22";
              "info.border" = hex "blue";
              hint = hex "cyan";
              "hint.background" = hexA "cyan" "22";
              "hint.border" = hex "cyan";

              # Git/file status (matches VSCode gitDecoration mapping)
              created = hex "green";
              "created.background" = hexA "green" "22";
              "created.border" = hex "green";
              modified = hex "yellow";
              "modified.background" = hexA "yellow" "22";
              "modified.border" = hex "yellow";
              deleted = hex "red";
              "deleted.background" = hexA "red" "22";
              "deleted.border" = hex "red";
              renamed = hex "cyan";
              "renamed.background" = hexA "cyan" "22";
              "renamed.border" = hex "cyan";
              conflict = hex "magenta";
              "conflict.background" = hexA "magenta" "22";
              "conflict.border" = hex "magenta";
              ignored = hex "muted";
              "ignored.background" = hexA "muted" "22";
              "ignored.border" = hex "muted";
              hidden = hex "muted";
              "hidden.background" = hexA "muted" "22";
              "hidden.border" = hex "muted";

              predictive = hex "muted";
              "predictive.background" = hexA "purple" "22";
              "predictive.border" = hex "purple";
              unreachable = hex "muted";
              "unreachable.background" = hexA "muted" "22";
              "unreachable.border" = hex "muted";

              # Scrollbar
              "scrollbar.thumb.background" = hexA "ui" "80";
              "scrollbar.thumb.hover_background" = hex "uiAlt";
              "scrollbar.thumb.border" = hex "ui";
              "scrollbar.track.background" = hex "bg";
              "scrollbar.track.border" = hex "bg";

              # Terminal (matches VSCode terminal colors)
              "terminal.background" = hex "bg";
              "terminal.foreground" = hex "fg";
              "terminal.bright_foreground" = hex "whiteAlt";
              "terminal.dim_foreground" = hex "muted";
              "terminal.ansi.background" = hex "bg";
              "terminal.ansi.black" = hex "black";
              "terminal.ansi.red" = hex "red";
              "terminal.ansi.green" = hex "green";
              "terminal.ansi.yellow" = hex "yellow";
              "terminal.ansi.blue" = hex "blue";
              "terminal.ansi.magenta" = hex "magenta";
              "terminal.ansi.cyan" = hex "cyan";
              "terminal.ansi.white" = hex "fg";
              "terminal.ansi.bright_black" = hex "muted";
              "terminal.ansi.bright_red" = hex "red";
              "terminal.ansi.bright_green" = hex "green";
              "terminal.ansi.bright_yellow" = hex "yellow";
              "terminal.ansi.bright_blue" = hex "blue";
              "terminal.ansi.bright_magenta" = hex "magenta";
              "terminal.ansi.bright_cyan" = hex "cyan";
              "terminal.ansi.bright_white" = hex "whiteAlt";
              "terminal.ansi.dim_black" = hex "black";
              "terminal.ansi.dim_red" = hex "redAlt";
              "terminal.ansi.dim_green" = hex "greenAlt";
              "terminal.ansi.dim_yellow" = hex "yellowAlt";
              "terminal.ansi.dim_blue" = hex "blueAlt";
              "terminal.ansi.dim_magenta" = hex "magentaAlt";
              "terminal.ansi.dim_cyan" = hex "cyanAlt";
              "terminal.ansi.dim_white" = hex "fgAlt";

              accents = [
                (hex "accent")
                (hex "blue")
                (hex "green")
                (hex "yellow")
                (hex "magenta")
                (hex "cyan")
                (hex "purple")
              ];

              players = [
                {
                  cursor = hex "accent";
                  background = hex "accent";
                  selection = hexA "accent" "44";
                }
                {
                  cursor = hex "blue";
                  background = hex "blue";
                  selection = hexA "blue" "44";
                }
                {
                  cursor = hex "green";
                  background = hex "green";
                  selection = hexA "green" "44";
                }
                {
                  cursor = hex "magenta";
                  background = hex "magenta";
                  selection = hexA "magenta" "44";
                }
                {
                  cursor = hex "yellow";
                  background = hex "yellow";
                  selection = hexA "yellow" "44";
                }
                {
                  cursor = hex "cyan";
                  background = hex "cyan";
                  selection = hexA "cyan" "44";
                }
                {
                  cursor = hex "purple";
                  background = hex "purple";
                  selection = hexA "purple" "44";
                }
                {
                  cursor = hex "orange";
                  background = hex "orange";
                  selection = hexA "orange" "44";
                }
              ];

              # Syntax — user-supplied palette
              syntax = let
                sAttribute = "#dedede";
                sComment = "#7a7a7a";
                sConstant = "#937dff";
                sFunction = "#f0be6e";
                sKeyword = "#d97934";
                sNumber = "#99c2ff";
                sOperator = "#6aa68c";
                sProperty = "#bd87c9";
                sBracket = "#fcd247";
                sDelimiter = "#7a7a7a";
                sString = "#63945c";
                sTag = "#f0be6e";
                sType = "#f0be6e";
                sVariable = "#dedede";
                sHint = "#7a7a7a";
              in {
                attribute = {color = sAttribute;};
                boolean = {color = sConstant;};
                comment = {
                  color = sComment;
                  font_style = "italic";
                };
                "comment.doc" = {
                  color = sComment;
                  font_style = "italic";
                };
                constant = {color = sConstant;};
                constructor = {color = sType;};
                embedded = {color = sVariable;};
                emphasis = {
                  color = sVariable;
                  font_style = "italic";
                };
                "emphasis.strong" = {
                  color = sVariable;
                  font_weight = 700;
                };
                enum = {color = sType;};
                function = {color = sFunction;};
                "function.method" = {color = sFunction;};
                "function.builtin" = {color = sFunction;};
                hint = {color = sHint;};
                keyword = {color = sKeyword;};
                label = {color = sNumber;};
                link_text = {
                  color = sNumber;
                  font_style = "italic";
                };
                link_uri = {color = sNumber;};
                number = {color = sNumber;};
                operator = {color = sOperator;};
                predictive = {
                  color = sHint;
                  font_style = "italic";
                };
                preproc = {color = sKeyword;};
                primary = {color = sVariable;};
                property = {color = sProperty;};
                punctuation = {color = sVariable;};
                "punctuation.bracket" = {color = sBracket;};
                "punctuation.delimiter" = {color = sDelimiter;};
                "punctuation.list_marker" = {color = hex "accent";};
                "punctuation.special" = {color = sProperty;};
                string = {color = sString;};
                "string.escape" = {color = sKeyword;};
                "string.regex" = {color = sOperator;};
                "string.special" = {color = sConstant;};
                "string.special.symbol" = {color = sConstant;};
                tag = {color = sTag;};
                "text.literal" = {color = sString;};
                title = {
                  color = hex "accent";
                  font_weight = 700;
                };
                type = {color = sType;};
                "type.builtin" = {color = sType;};
                variable = {color = sVariable;};
                "variable.special" = {color = sProperty;};
                variant = {color = sType;};
              };
            };
          }
        ];
      };
    };
  };
}
