# Karabiner-Elements on darwin: ports the keyd/Linux keyboard habits onto macOS.
# This generated JSON is the source of truth; Karabiner may normalise the on-disk
# copy on launch, but our rules reapply on every activation.
{
  flake.modules.darwin.karabiner = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf config.fireproof.desktop.enable {
      homebrew.casks = ["karabiner-elements"];
    };
  };

  flake.modules.homeManager.karabiner = {
    config,
    lib,
    pkgs,
    ...
  }: let
    # Apps where Ctrl must stay Ctrl (SIGINT/readline). Add VS Code's id
    # ("^com\\.microsoft\\.VSCode$") if its integrated terminal losing Ctrl+C bites.
    terminalBundles = ["^com\\.mitchellh\\.ghostty$"];
    unlessTerminal = [
      {
        type = "frontmost_application_unless";
        bundle_identifiers = terminalBundles;
      }
    ];

    # Linux app shortcuts to re-home onto Cmd. Omitting q (accidental Cmd+Q quit),
    # h (Cmd+H hides), and m/e/k/d (emacs-style text-field bindings rarely wanted
    # moved). optional "any" carries Shift through, so Ctrl+Shift+T → Cmd+Shift+T.
    ctrlToCmdKeys = ["a" "c" "v" "x" "z" "s" "f" "t" "w" "n" "r" "p" "o" "g" "l"];
    mkCtrlToCmd = key: {
      type = "basic";
      from = {
        key_code = key;
        modifiers = {
          mandatory = ["control"];
          optional = ["any"];
        };
      };
      to = [
        {
          key_code = key;
          modifiers = ["left_command"];
        }
      ];
      conditions = unlessTerminal;
    };

    # PC-style caret nav: Home/End = line, Ctrl+Home/End = document, Ctrl+arrows =
    # word. Exact modifier sets (no broad optional) keep the Shift selection
    # variants from colliding with the plain ones.
    mkNav = {
      fromKey,
      fromMods ? [],
      toKey,
      toMods,
    }: {
      type = "basic";
      from = {
        key_code = fromKey;
        modifiers = {
          mandatory = fromMods;
          optional = ["caps_lock"];
        };
      };
      to = [
        {
          key_code = toKey;
          modifiers = toMods;
        }
      ];
      conditions = unlessTerminal;
    };
    navRules = [
      (mkNav {
        fromKey = "home";
        toKey = "left_arrow";
        toMods = ["left_command"];
      })
      (mkNav {
        fromKey = "end";
        toKey = "right_arrow";
        toMods = ["left_command"];
      })
      (mkNav {
        fromKey = "home";
        fromMods = ["shift"];
        toKey = "left_arrow";
        toMods = ["left_command" "left_shift"];
      })
      (mkNav {
        fromKey = "end";
        fromMods = ["shift"];
        toKey = "right_arrow";
        toMods = ["left_command" "left_shift"];
      })
      (mkNav {
        fromKey = "home";
        fromMods = ["control"];
        toKey = "up_arrow";
        toMods = ["left_command"];
      })
      (mkNav {
        fromKey = "end";
        fromMods = ["control"];
        toKey = "down_arrow";
        toMods = ["left_command"];
      })
      (mkNav {
        fromKey = "home";
        fromMods = ["control" "shift"];
        toKey = "up_arrow";
        toMods = ["left_command" "left_shift"];
      })
      (mkNav {
        fromKey = "end";
        fromMods = ["control" "shift"];
        toKey = "down_arrow";
        toMods = ["left_command" "left_shift"];
      })
      (mkNav {
        fromKey = "left_arrow";
        fromMods = ["control"];
        toKey = "left_arrow";
        toMods = ["left_option"];
      })
      (mkNav {
        fromKey = "right_arrow";
        fromMods = ["control"];
        toKey = "right_arrow";
        toMods = ["left_option"];
      })
      (mkNav {
        fromKey = "left_arrow";
        fromMods = ["control" "shift"];
        toKey = "left_arrow";
        toMods = ["left_option" "left_shift"];
      })
      (mkNav {
        fromKey = "right_arrow";
        fromMods = ["control" "shift"];
        toKey = "right_arrow";
        toMods = ["left_option" "left_shift"];
      })
    ];

    karabinerConfig = {
      global.show_in_menu_bar = false;
      profiles = [
        {
          name = "Fireproof";
          selected = true;
          # Without this, every activation rewrites karabiner.json with no keyboard
          # type set, so Karabiner re-prompts for ISO/ANSI/JIS on next launch.
          virtual_hid_keyboard.keyboard_type_v2 = "iso";
          complex_modifications.rules = [
            {
              description = "CapsLock → Backspace (match keyd)";
              manipulators = [
                {
                  type = "basic";
                  from = {
                    key_code = "caps_lock";
                    modifiers.optional = ["any"];
                  };
                  to = [{key_code = "delete_or_backspace";}];
                }
              ];
            }
            {
              description = "Ctrl → Cmd for app shortcuts (except terminal)";
              manipulators = map mkCtrlToCmd ctrlToCmdKeys;
            }
            {
              description = "PC-style Home/End + Ctrl-arrow word nav (except terminal)";
              manipulators = navRules;
            }
            {
              # Danish Apple layout puts @ on Option + the '/* key (macOS keycode
              # 42, Karabiner "backslash") — not Option+2. Re-home it to the
              # PC-muscle-memory right-Cmd+2.
              description = "Right Cmd + 2 → @ (Danish layout)";
              manipulators = [
                {
                  type = "basic";
                  from = {
                    key_code = "2";
                    modifiers.mandatory = ["right_command"];
                  };
                  to = [
                    {
                      key_code = "backslash";
                      modifiers = ["left_option"];
                    }
                  ];
                }
              ];
            }
          ];
        }
      ];
    };

    configFile = (pkgs.formats.json {}).generate "karabiner.json" karabinerConfig;
  in {
    # Materialise a real file, not a symlink: Karabiner rewrites karabiner.json in
    # place (replacing a symlink with a regular file), so a home.file link would be
    # clobbered. It reloads on write; the kickstart is a belt-and-braces nudge.
    config = lib.mkIf (config.fireproof.desktop.enable && pkgs.stdenv.isDarwin) {
      home.activation.karabiner = lib.hm.dag.entryAfter ["writeBoundary"] ''
        $DRY_RUN_CMD mkdir -p "$HOME/.config/karabiner"
        $DRY_RUN_CMD rm -f "$HOME/.config/karabiner/karabiner.json"
        $DRY_RUN_CMD install -m644 ${configFile} "$HOME/.config/karabiner/karabiner.json"
        $DRY_RUN_CMD /bin/launchctl kickstart -k "gui/$(/usr/bin/id -u)/org.pqrs.karabiner.karabiner_console_user_server" 2>/dev/null || true
      '';
    };
  };
}
