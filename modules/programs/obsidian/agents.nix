# Agent support for the notes vault: the official CLI, a /notes skill for other repos,
# and vault-scoped skills plus git snapshot hooks for sessions run inside the vault.
# Conventions live in the vault's own AGENTS.md.
{
  flake.modules.homeManager.obsidian-agents = {
    config,
    lib,
    pkgs,
    ...
  }: let
    vault = config.programs.obsidian.vaults.notes.target;

    # The cask's CLI; on Linux the nixpkgs build ships obsidian-cli itself.
    cli =
      if pkgs.stdenv.isDarwin
      then
        pkgs.writeShellScriptBin "obsidian-cli" ''
          exec /Applications/Obsidian.app/Contents/MacOS/obsidian-cli "$@"
        ''
      else config.programs.obsidian.package;

    check = pkgs.writers.writePython3Bin "obsidian-vault-check" {
      libraries = [pkgs.python3Packages.pyyaml];
      flakeIgnore = ["E501"];
    } (builtins.readFile ./vault-check.py);

    # Local, never-pushed history: an undo log that keeps agent edits apart from synced ones.
    snapshot = pkgs.writeShellApplication {
      name = "obsidian-vault-snapshot";
      runtimeInputs = [pkgs.git];
      text = ''
        cd "$HOME/${vault}"
        [ -d .git ] || git init -q
        printf '%s\n' .obsidian/ .claude/ .trash/ >.git/info/exclude
        git add -A
        git diff --cached --quiet || git -c commit.gpgsign=false commit -q --no-verify -m "$1"
      '';
    };

    # The Linter only runs inside Obsidian, so lint what the session changed through the
    # running app; without it the note is linted on its next save instead.
    lint = pkgs.writeShellApplication {
      name = "obsidian-vault-lint";
      runtimeInputs = [pkgs.git pkgs.jq cli];
      text = ''
        cd "$HOME/${vault}"
        [ -d .git ] || exit 0
        mapfile -d "" files < <(git ls-files -z --modified --others --exclude-standard -- \
          '*.md' ':!:Templates/' ':!:Attachments/' ':!:AGENTS.md')
        [ "''${#files[@]}" -gt 0 ] || exit 0
        paths=$(printf '%s\0' "''${files[@]}" | jq -Rsc 'split("\u0000")[:-1]')
        obsidian-cli vault=${baseNameOf vault} eval code="(async () => {
          const linter = app.plugins.plugins['obsidian-linter'];
          for (const path of $paths) {
            const file = app.vault.getFileByPath(path);
            if (linter && file) await linter.runLinterFile(file);
          }
        })()" >/dev/null 2>&1 || true
      '';
    };

    hook = command: [
      {
        hooks = [
          {
            inherit command;
            type = "command";
          }
        ];
      }
    ];
    settings = (pkgs.formats.json {}).generate "claude-settings.json" {
      hooks = {
        SessionStart = hook "${lib.getExe snapshot} 'snapshot before agent session'";
        Stop = hook (lib.getExe lint);
        SessionEnd = hook "${lib.getExe snapshot} 'agent session'";
      };
    };

    kepano = pkgs.fetchFromGitHub {
      owner = "kepano";
      repo = "obsidian-skills";
      rev = "3ccff5338ea700537839b21900aa5358a0402c98";
      hash = "sha256-kyH07EVmwIEC/q6i91Kz8mPE78j9ITga2NZUpU1+nHU=";
    };
    vaultSkills =
      lib.genAttrs ["inbox" "check" "meeting"] (name: ./skills + "/${name}")
      // lib.genAttrs ["obsidian-markdown" "obsidian-bases" "obsidian-cli"] (name: "${kepano}/skills/${name}");
  in {
    config = lib.mkIf config.fireproof.desktop.enable {
      programs.obsidian.cli.enable = true;
      home.packages = [check] ++ lib.optional pkgs.stdenv.isDarwin cli;

      fireproof.agents.skills.notes = ./skills/notes;

      home.file =
        {"${vault}/.claude/settings.json".source = settings;}
        // lib.mapAttrs' (name: source: lib.nameValuePair "${vault}/.claude/skills/${name}" {inherit source;}) vaultSkills;
    };
  };
}
