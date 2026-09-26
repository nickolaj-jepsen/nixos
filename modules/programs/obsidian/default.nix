# Obsidian vaults synced by Self-hosted LiveSync against the homelab CouchDB
# (modules/homelab/obsidian-sync.nix). App settings are Nix-managed and read-only;
# plugins (plugins.nix) and LiveSync (livesync.nix) live beside this file.
# `notes` is the working vault; `legacy` is the pre-2026 vault, kept as a read-only archive.
{fpLib, ...}: {
  flake.modules.homeManager.obsidian = {
    config,
    lib,
    pkgs,
    ...
  }: let
    c = config.fireproof.theme.colors;
    vaultCfg = config.programs.obsidian.vaults;

    app = {
      alwaysUpdateLinks = true;
      newLinkFormat = "shortest";
      spellcheck = true;
      spellcheckLanguages = ["en-US" "da"];
      pdfExportSettings = {
        includeName = true;
        pageSize = "A4";
        landscape = false;
        margin = "0";
        downscalePercent = 100;
      };
    };

    # Paths programs.obsidian links into a vault; a vault predating Nix has them as regular files.
    managedPaths = vault:
      [
        "app.json"
        "appearance.json"
        "community-plugins.json"
        "core-plugins.json"
        "snippets/better-presentation.css"
        "snippets/fireproof.css"
      ]
      ++ lib.optional (vaultCfg.${vault}.settings.hotkeys != null) "hotkeys.json"
      ++ map (p: "plugins/${(p.pkg or p).manifestId}") vaultCfg.${vault}.settings.communityPlugins;
  in {
    config = lib.mkIf config.fireproof.desktop.enable {
      programs.obsidian = {
        enable = true;
        # darwin installs the Homebrew cask (below); the nixpkgs build is Linux-only.
        package =
          if pkgs.stdenv.isLinux
          then pkgs.unstable.obsidian
          else null;

        defaultSettings = {
          appearance = {
            theme = "obsidian";
            accentColor = "#${c.accent}";
            # Same as Ghostty.
            monospaceFontFamily = "Hack Nerd Font Mono";
          };
          # Border's card layout (enabled via Style Settings in plugins.nix) gives the island look; the fireproof snippet colors it.
          themes = [pkgs.obsidianThemes.border];
          # Obsidian Sync ("sync") stays off: LiveSync replaces it. Templater replaces core "templates".
          corePlugins = [
            "backlink"
            "bases"
            "bookmarks"
            "canvas"
            "command-palette"
            "editor-status"
            "file-explorer"
            "file-recovery"
            "footnotes"
            "global-search"
            "graph"
            "note-composer"
            "outgoing-link"
            "outline"
            "page-preview"
            "properties"
            "slides"
            "switcher"
            "tag-pane"
            "word-count"
          ];
          cssSnippets = [
            {
              name = "fireproof";
              text = let
                accents = {
                  inherit (c) red orange yellow green cyan blue purple;
                  pink = c.magenta;
                };
                headings = lib.range 1 6;
                # Heading bar width in px: h1 widest, narrowing to 2.
                barWidth = n: lib.max 2 (7 - n);
                # VS Code's syntax theme (vscode/theme.nix uses "Darcula Theme from IntelliJ").
                darcula = {
                  normal = "A9B7C6";
                  comment = "808080";
                  function = "FFC66D";
                  important = "CC7832";
                  keyword = "CC7832";
                  operator = "A9B7C6";
                  property = "9876AA";
                  punctuation = "A9B7C6";
                  string = "6A8759";
                  tag = "FFC66D";
                  value = "6897BB";
                };
              in ''
                /* Doubled class outranks Border's .theme-dark.theme-dark-background-* palettes. */
                body.theme-dark.theme-dark {
                  --color-base-00: #${c.bg};
                  --color-base-05: #${c.bg};
                  --color-base-10: #${c.bg};
                  --color-base-20: #${c.bg};
                  --color-base-25: #${c.bgAlt};
                  --color-base-30: #${c.bgAlt};
                  --color-base-35: #${c.ui};
                  --color-base-40: #${c.uiAlt};
                  --color-base-70: #${c.muted};
                  --color-base-100: #${c.fg};

                  /* Like VS Code's modern UI (vscode/theme.nix): bg islands on a bgAlt backdrop (tertiary), fg text. */
                  --background-primary: #${c.bg};
                  --background-primary-alt: #${c.bgAlt};
                  --background-secondary: #${c.bg};
                  --background-secondary-alt: #${c.bgAlt};
                  --background-tertiary: #${c.bgAlt};
                  --background-modifier-border: #${c.ui};
                  --text-normal: #${c.fg};
                  --text-muted: #${c.muted};
                  --nav-item-color: #${c.fg};
                  /* Ribbon, tab and status bar text on the backdrop; Border tints it with the accent by default. */
                  --on-border-dark: #${c.fg};
                  --mix-blend-mode-on-border-dark: normal;

                  /* Plain bold/italic, and solid code backgrounds instead of Border's dotted pattern. */
                  --bold-color: var(--text-normal);
                  --italic-color: var(--text-normal);
                  --code-background-dark: #${c.bgAlt};
                  --code-border-dark: none;
                  --inline-code-background-dark: #${c.bgAlt};
                  --inline-code-normal: #${darcula.normal};
                ${lib.concatStrings (lib.mapAttrsToList (name: hex: "  --code-${name}: #${hex};\n") darcula)}

                  /* Heading bars fade from fg (h1) toward the editor background instead of Border's rainbow. */
                ${lib.concatMapStrings (n: "  --h${toString n}-accent-color: color-mix(in srgb, #${c.fg} ${toString (100 - (n - 1) * 100 / 6)}%, var(--background-primary));\n") headings}
                ${lib.concatStrings (lib.mapAttrsToList (name: hex: "  --color-${name}: #${hex};\n  --color-${name}-rgb: ${fpLib.hexToRgb hex};\n") accents)}}

                /* Border's heading bars are all 3px; the text indent keeps the 6px gap live preview has. */
                ${lib.concatMapStrings (n: let
                    h = toString n;
                  in ''
                    body:not(.heading-indicator-off) :is(.is-live-preview .HyperMD-header-${h}, .markdown-rendered > h${h}, .markdown-preview-sizer > div > h${h})::before {
                      width: ${toString (barWidth n)}px;
                    }
                    body:not(.heading-indicator-off) :is(.markdown-rendered > h${h}, .markdown-preview-sizer > div > h${h}) {
                      text-indent: ${toString (barWidth n + 6)}px;
                    }
                  '')
                  headings}
                /* Darcula bolds keywords. */
                .theme-dark :is(.markdown-rendered .token.keyword, .cm-s-obsidian span.cm-keyword) {
                  font-weight: bold;
                }

                /* niri draws no decorations and closes windows itself; drop Obsidian's min/max/close. */
                body.mod-linux .titlebar-button-container.mod-right {
                  display: none;
                }
              '';
            }
            {
              name = "better-presentation";
              text = ''
                .reveal {
                  font-size: 1.5em;
                  line-height: 2.5em;
                }

                .reveal .slides {
                  text-align: left !important;
                }

                .reveal .slides section,
                .reveal .slides section > section {
                  line-height: 1.8em;
                }

                .reveal code {
                  line-height: 1.3em !important;
                }

                .reveal .copy-code-button {
                  display: none;
                }

                .reveal ul {
                  width: 100%;
                  margin-left: 0 !important;
                }
              '';
            }
          ];
        };

        vaults = {
          notes = {
            target = "obsidian/notes";
            settings.app =
              app
              // {
                attachmentFolderPath = "Attachments";
                newFileLocation = "folder";
                newFileFolderPath = "Inbox";
                # Demoted in the switcher and link suggestions, hidden from search and graph; Templater still reads them.
                userIgnoreFilters = ["Templates/"];
              };
            # Mod is Ctrl, or Cmd on macOS. A binding replaces the command's defaults, so keep those listed too.
            settings.hotkeys = let
              hk = modifiers: key: {inherit modifiers key;};
            in {
              "file-explorer:move-file" = [(hk ["Mod" "Shift"] "M")];
              "note-composer:merge-file" = [(hk ["Mod" "Shift"] "J")];
              # Templater's own Alt+N default is unset on macOS.
              "templater-obsidian:create-new-note-from-template" = [(hk ["Mod" "Alt"] "N")];
              # JetBrains keymap: go to file, find action, reformat.
              # Ctrl+Space too, Ctrl even on macOS where Cmd+Space is Spotlight.
              "switcher:open" = [(hk ["Mod"] "O") (hk ["Mod" "Shift"] "N") (hk ["Ctrl"] " ")];
              "file-explorer:new-file-in-new-pane" = [];
              "command-palette:open" = [(hk ["Mod"] "P") (hk ["Mod" "Shift"] "A")];
              # Formats code blocks, then lints (plugins.nix).
              "fireproof:format-note" = [(hk ["Mod" "Shift"] "P")];
              # Mod+Enter jumps to the Claude terminal (opening one if needed) and back. Leaving uses
              # Terminal's unfocus: only its own commands get through while a terminal has focus, and
              # unlike its toggle it declines when none does, so Obsidian falls through to ours.
              # Takes Mod+Enter from "open link under cursor in new tab" (Ctrl+click does it).
              "fireproof:toggle-terminal" = [(hk ["Mod"] "Enter")];
              "terminal:unfocus-terminal" = [(hk ["Mod"] "Enter")];
              "editor:open-link-in-new-leaf" = [];
            };
          };
          legacy = {
            target = "obsidian/legacy";
            settings.app =
              app
              // {
                attachmentFolderPath = "_assets";
                newFileLocation = "root";
                defaultViewMode = "preview";
              };
          };
        };
      };

      home.file = lib.listToAttrs (lib.concatMap (vault:
        map (path: lib.nameValuePair "${vaultCfg.${vault}.target}/.obsidian/${path}" {force = true;}) (managedPaths vault))
      (lib.attrNames vaultCfg));
    };
  };

  # On darwin the nixpkgs build isn't used; install the Homebrew cask instead.
  flake.modules.darwin.obsidian = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf config.fireproof.desktop.enable {
      homebrew.casks = ["obsidian"];
    };
  };
}
