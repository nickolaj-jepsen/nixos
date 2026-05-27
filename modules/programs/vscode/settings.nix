{
  config,
  lib,
  pkgs,
  ...
}: let
  mkFormatter = formatter: languages: {
    "[${lib.concatStringsSep "][" languages}]" = {
      "editor.defaultFormatter" = formatter;
    };
  };
in {
  config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.dev.enable) {
    fireproof.home-manager.programs.vscode.profiles.default = {
      enableUpdateCheck = true;
      enableExtensionUpdateCheck = true;
      keybindings = [
        {
          "key" = "ctrl+shift+p";
          "command" = "editor.action.formatDocument";
        }
      ];
      userSettings = lib.mkMerge [
        {
          # General
          "extensions.ignoreRecommendations" = true;
          "telemetry.telemetryLevel" = "off";
          "update.mode" = "none"; # Managed by Nix

          # Editor
          "editor.linkedEditing" = true;
          "editor.formatOnPaste" = true;
          "editor.bracketPairColorization.enabled" = true;
          "editor.guides.bracketPairs" = "active";
          "editor.cursorSmoothCaretAnimation" = "on";
          "editor.stickyScroll.enabled" = true;
          "editor.inlayHints.enabled" = "onUnlessPressed";
          "editor.renderWhitespace" = "boundary";
          "editor.suggestSelection" = "first";
          "editor.unicodeHighlight.invisibleCharacters" = true;

          # Problems panel
          "problems.sortOrder" = "severity";
          "problems.showCurrentInStatus" = true;

          # Files
          "files.autoSave" = "afterDelay";
          "files.trimTrailingWhitespace" = true;
          "files.insertFinalNewline" = true;
          "files.trimFinalNewlines" = true;
          "files.exclude" = {
            "**/*.egg-info" = true;
            "**/__pycache__" = true;
            "**/.git" = true;
            "**/.DS_Store" = true;
            "**/node_modules" = true;
            "**/.direnv" = true;
          };
          "files.watcherExclude" = {
            "**/.direnv/**" = true;
            "**/node_modules/**" = true;
            "**/result" = true;
            "**/result-*" = true;
          };

          # Search
          "search.useIgnoreFiles" = true;
          "search.exclude" = {
            "**/node_modules" = true;
            "**/.direnv" = true;
            "**/dist" = true;
            "**/.next" = true;
            "**/__pycache__" = true;
            "**/*.lock" = true;
          };

          # Explorer
          "explorer.confirmDragAndDrop" = false;
          "explorer.fileNesting.enabled" = true;
          "explorer.fileNesting.patterns" = {
            "*.ts" = "\${capture}.js, \${capture}.test.ts, \${capture}.spec.ts";
            "package.json" = "package-lock.json, pnpm-lock.yaml, yarn.lock, .npmrc, .nvmrc";
            "tsconfig.json" = "tsconfig.*.json";
            "flake.nix" = "flake.lock";
          };

          # Workbench
          "workbench.editor.wrapTabs" = true;
          "workbench.startupEditor" = "none";
          "workbench.tree.indent" = 16;
          "workbench.editor.highlightModifiedTabs" = true;
          "workbench.editor.limit.enabled" = true;
          "workbench.editor.limit.value" = 10;
          "workbench.editor.limit.perEditorGroup" = true;

          # Terminal
          "terminal.integrated.defaultProfile.linux" = "fish";
          "terminal.integrated.smoothScrolling" = true;
          "terminal.integrated.cursorBlinking" = true;
          "terminal.integrated.fontFamily" = "'Hack Nerd Font Mono', monospace";
          "terminal.integrated.scrollback" = 10000;

          # Remote
          "remote.SSH.useLocalServer" = false;
          "remote.SSH.remotePlatform" = lib.mapAttrs (_name: _value: "linux") config.fireproof.home-manager.programs.ssh.settings;

          # AI
          "github.copilot.enable" = {
            "*" = true;
            "plaintext" = true;
            "markdown" = true;
            "scminput" = true;
          };
          "github.copilot.chat.claudeAgent.enabled" = true;
          "github.copilot.chat.copilotMemory.enabled" = true;
          "chat.viewSessions.orientation" = "vertical";
          "chat.agent.maxRequests" = 100;
          "chat.tools.terminal.autoApprove" = {
            "nix" = true;
            "cat" = true;
            "ls" = true;
            "head" = true;
            "tail" = true;
            "find" = true;
            "grep" = true;
            "rg" = true;
            "fd" = true;
            "echo" = true;
            "jq" = true;
            "pwd" = true;
            "wc" = true;
            "which" = true;
            "git status" = true;
            "git log" = true;
            "git diff" = true;
            "git branch" = true;
            "git show" = true;
            "uv" = true;
            "python" = true;
            "pip" = true;
            "npm" = true;
            "npx" = true;
            "pnpm" = true;
            "yarn" = true;
            "node" = true;
            "cargo" = true;
            "rustc" = true;
            "go" = true;
            "just" = true;
            "make" = true;
            "uniq" = true;
          };

          # Keybindings
          "workbench.commandPalette.experimental.suggestCommands" = true; # Emulates IntelliJ's "Search Everywhere"

          # Git
          "git.autofetch" = true;
          "git.confirmSync" = false;
          "git.enableSmartCommit" = true;
          "git.blame.editorDecoration.enabled" = true;
          "git.fetchOnPull" = true;
          "git.pruneOnFetch" = true;
          "git.confirmForcePush" = true;
          "git.untrackedChanges" = "separate";
          "git.openRepositoryInParentFolders" = "always";
          "diffEditor.ignoreTrimWhitespace" = false;
          "diffEditor.experimental.showMoves" = true;
          "scm.repositories.explorer" = true;

          # GitHub
          "githubPullRequests.codingAgent.uiIntegration" = true;
          "githubPullRequests.pullBranch" = "always";

          # nix-ide
          "nix.enableLanguageServer" = true;
          "nix.serverPath" = lib.getExe pkgs.nil;
          "nix.serverSettings" = {
            nil.formatting.command = ["nix" "fmt" "--" "--"];
          };

          # Python
          "python.analysis.autoImportCompletions" = true;
          "python.languageServer" = "None";

          # Spell checking
          "cSpell.language" = "en,da";
          "cSpell.diagnosticLevel" = "Hint";
          "cSpell.userWords" = [
            "aonumber"
            "aortl"
            "billigvvs"
            "bvvs"
            "completvvs"
            "costprice"
            "currentpriceamount"
            "customercenter"
            "eannumber"
            "enddate"
            "groupid"
            "growthbook"
            "klaviyo"
            "linksto"
            "pricehub"
            "productbox"
            "productcard"
            "productgroup"
            "productid"
            "productlist"
            "productname"
            "productnumber"
            "rebatecode"
            "salesprice"
            "sortorder"
            "ttag"
            "unitcount"
            "unitprice"
            "vendornumber"
            "vvskupp"
            "vvseksperten"
            "walley"
            "claude"
            "nixos"
            "nickolaj"
            "homelab"
            "pkgs"
          ];

          # JSON
          "json.schemaDownload.trustedDomains" = {
            "https://biomejs.dev" = true;
            "https://json-schema.org/" = true;
            "https://json.schemastore.org/" = true;
            "https://www.schemastore.org/" = true;
            "https://raw.githubusercontent.com/" = true;
            "https://schemastore.azurewebsites.net/" = true;
          };

          # Other extensions
          "biome.suggestInstallingGlobally" = false;

          # Error Lens
          "errorLens.messageBackgroundMode" = "none";
          "errorLens.followCursor" = "allLines";
          "errorLens.gutterIconsEnabled" = true;
          "errorLens.fontStyleItalic" = true;
          "errorLens.excludeBySource" = ["cSpell"];

          # Direnv
          "direnv.restart.automatic" = true;
          "direnv.status.showOnStartup" = false;
        }
        (mkFormatter "oxc.oxc-vscode" ["json" "jsonc" "markdown" "css" "scss" "typescript" "typescriptreact" "html" "yaml"])
        (mkFormatter "charliermarsh.ruff" ["python"])
      ];
    };
  };
}
