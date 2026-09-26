# Community plugins per vault. Plugin code is linked read-only from the
# nix-obsidian-extensions overlay; settings are merged into each plugin's data.json
# on activation instead, since most plugins rewrite that file at runtime. Keys set
# here win on every switch; anything else the plugin stores is kept.
{
  flake.modules.homeManager.obsidian-plugins = {
    config,
    lib,
    pkgs,
    ...
  }: let
    p = pkgs.obsidianPlugins;
    vaultCfg = config.programs.obsidian.vaults;

    listCallouts = [
      {
        color = "255, 214, 0";
        char = "&";
      }
      {
        color = "255, 145, 0";
        char = "?";
      }
      {
        color = "255, 23, 68";
        char = "!";
      }
      {
        color = "124, 77, 255";
        char = "~";
      }
      {
        color = "0, 184, 212";
        char = "@";
      }
      {
        color = "0, 200, 83";
        char = "$";
      }
      {
        color = "158, 158, 158";
        char = "%";
      }
      {
        char = "throw";
        color = "173, 175, 136";
        icon = "lucide-hand";
        custom = true;
      }
      {
        char = "wait";
        color = "255, 255, 255";
        icon = "lucide-alarm-clock";
        custom = true;
      }
      {
        char = "move";
        color = "70, 221, 203";
        icon = "lucide-corner-up-right";
        custom = true;
      }
    ];

    # Image Converter wants every field on a preset; these are its defaults, no resizing.
    conversionPreset = preset:
      {
        colorDepth = 1;
        resizeMode = "None";
        desiredWidth = 800;
        desiredHeight = 600;
        desiredLongestEdge = 1000;
        enlargeOrReduce = "Auto";
        allowLargerFiles = false;
        revertToOriginalIfLarger = false;
        minimumCompressionSavingsInKB = 30;
        skipConversionPatterns = "";
        pngquantExecutablePath = "";
        pngquantQuality = "65-80";
        ffmpegExecutablePath = "";
        ffmpegCrf = 23;
        ffmpegPreset = "medium";
      }
      // preset;

    # Border's layout switches are class toggles, which only Style Settings can set.
    styleSettings = {
      pkg = p.obsidian-style-settings;
      settings = {
        "Appearance-dark@@card-layout-open-dark" = true;
        # Keep the bar before each heading; the fireproof snippet grays it. Explicit, as the merge keeps stale keys.
        "Editor@@heading-indicator-off" = false;
      };
    };

    # vault -> [{pkg, settings?}]
    plugins = {
      notes = [
        {pkg = p.obsidian-livesync;}
        styleSettings
        {
          # "Trigger on file creation" lives in per-device localStorage, not data.json, so flip its
          # default instead. Safe with sync: Templater only fills files whose body is empty.
          pkg = p.templater-obsidian.overrideAttrs (old: {
            buildCommand =
              old.buildCommand
              + ''
                substituteInPlace "$out/main.js" --replace-fail \
                  '{trigger_on_file_creation:!1,' '{trigger_on_file_creation:!0,'
              '';
          });
          settings = {
            data_version = 2;
            templates_folder = "Templates";
            trigger_on_file_creation_mode = "folder";
            auto_jump_to_cursor = true;
            folder_templates = map (folder: {
              inherit folder;
              template = "Templates/${folder}.md";
            }) ["Inbox" "Notes" "Meetings" "Projects" "Recipes" "Writing"];
          };
        }
        {
          pkg = p.obsidian-excalidraw-plugin;
          settings = {
            folder = "Attachments";
            embedUseExcalidrawFolder = false;
          };
        }
        {
          pkg = p.obsidian-list-callouts;
          settings = listCallouts;
        }
        {
          pkg = p.obsidian-linter;
          settings = {
            # Otherwise the plugin "migrates" these key-based rule configs on load.
            settingsConvertedToConfigKeyValues = true;
            lintOnSave = true;
            displayChanged = false;
            foldersToIgnore = ["Templates" "Attachments"];
            ruleConfigs = {
              # created only, never rewritten; a modified stamp would churn sync between devices.
              yaml-timestamp = {
                enabled = true;
                date-created = true;
                date-created-key = "created";
                date-created-source-of-truth = "frontmatter";
                date-modified = false;
                format = "YYYY-MM-DD";
                update-on-file-contents-updated = "never";
              };
              yaml-key-sort = {
                enabled = true;
                yaml-key-priority-sort-order = lib.concatStringsSep "\n" [
                  "created"
                  "area"
                  "tags"
                  "kind"
                  "status"
                  "date"
                  "event"
                  "attendees"
                  "project"
                  "started"
                  "ended"
                  "source"
                  "servings"
                ];
                priority-keys-at-start-of-yaml = true;
                yaml-sort-order-for-other-keys = "None";
              };
              trailing-spaces = {
                enabled = true;
                two-space-line-break = false;
              };
              consecutive-blank-lines.enabled = true;
              heading-blank-lines = {
                enabled = true;
                bottom = true;
                empty-line-after-yaml = true;
              };
              line-break-at-document-end.enabled = true;
            };
          };
        }
        {
          pkg = p.image-converter;
          settings = {
            selectedFolderPreset = "Default (Obsidian setting)";
            selectedFilenamePreset = "NoteName-Timestamp";
            selectedConversionPreset = "WebP 85";
            modalBehavior = "never";
            conversionPresets = [
              (conversionPreset {
                name = "None";
                outputFormat = "NONE";
                quality = 100;
              })
              (conversionPreset {
                name = "WebP 85";
                outputFormat = "WEBP";
                quality = 85;
                revertToOriginalIfLarger = true;
                minimumCompressionSavingsInKB = 0;
              })
            ];
          };
        }
      ];

      # Only what's needed to render the archive.
      legacy = [
        {pkg = p.obsidian-livesync;}
        styleSettings
        {pkg = p.obsidian-excalidraw-plugin;}
        {pkg = p.dataview;}
        {
          pkg = p.obsidian-list-callouts;
          settings = listCallouts;
        }
      ];
    };

    jq = lib.getExe pkgs.jq;
    settingsFormat = pkgs.formats.json {};
    mergeSettings = vault: plugin: let
      file = "$HOME/${vaultCfg.${vault}.target}/.obsidian/plugins/${plugin.pkg.manifestId}/data.json";
    in ''
      run obsidian_merge_settings "${file}" ${settingsFormat.generate "${plugin.pkg.manifestId}-data.json" plugin.settings}
    '';
  in {
    config = lib.mkIf config.fireproof.desktop.enable {
      programs.obsidian.vaults = lib.mapAttrs (_: list: {settings.communityPlugins = map (x: x.pkg) list;}) plugins;

      home.activation.obsidianPluginSettings = lib.hm.dag.entryAfter ["linkGeneration"] ''
        obsidian_merge_settings() {
          local file=$1 nix=$2 old tmp
          # Objects deep-merge over the current file (missing, empty or invalid counts as none); other JSON replaces it.
          old=$(${jq} -c . "$file" 2>/dev/null) || old=null
          [ -n "$old" ] || old=null
          mkdir -p "$(dirname "$file")"
          tmp=$(mktemp)
          ${jq} --argjson old "$old" 'if type == "object" and ($old | type) == "object" then $old * . else . end' "$nix" >"$tmp"
          rm -f "$file"
          install -m600 "$tmp" "$file"
          rm -f "$tmp"
        }
        ${lib.concatStrings (lib.concatLists (lib.mapAttrsToList (vault: list:
          map (mergeSettings vault) (lib.filter (x: x ? settings) list))
        plugins))}
      '';
    };
  };
}
