{
  # darwin installs the cask; Linux installs the nixpkgs build (HM half below).
  flake.modules.darwin.sublime-merge = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.dev.enable) {
      homebrew.casks = ["sublime-merge"];
    };
  };

  flake.modules.homeManager.sublime-merge = {
    config,
    lib,
    pkgs,
    ...
  }: let
    # Sublime Merge has no plugin API, so "custom packages" means these files in
    # Packages/User. Nix owns them instead of the in-app Preferences editor,
    # which therefore can't save into the store symlinks.
    userDir =
      if pkgs.stdenv.isDarwin
      then "${config.home.homeDirectory}/Library/Application Support/Sublime Merge/Packages/User"
      else "${config.xdg.configHome}/sublime-merge/Packages/User";

    # Every non-git tool goes through an `sm-*` alias in modules/programs/git.nix:
    # the `git` command is the only argv the command palette can run, and paths
    # baked into the alias work without the GUI process inheriting a shell PATH.
    run = caption: argv: {
      inherit caption;
      command = "git";
      args = {inherit argv;};
    };

    # Opens an agent in its own Ghostty window at the directory the menu was used
    # on, with the review prompt as its first message.
    agentLauncher = pkgs.writeShellApplication {
      name = "sm-agent";
      runtimeInputs = lib.optional (!pkgs.stdenv.isDarwin) config.programs.ghostty.package;
      text = ''
        # sm-agent <pi|claude|claude-work> <dir> <prompt>
        agent=$1
        dir=$2
        prompt=$3

        case $agent in
          claude) bin=$HOME/.local/bin/claude ;;
          *) bin=$(command -v "$agent" || true) ;;
        esac
        if [ -z "''${bin:-}" ] || [ ! -x "$bin" ]; then
          echo "sm-agent: no '$agent' binary" >&2
          exit 1
        fi
        # An unsubstituted "$dir" from a menu, or "." from a palette command,
        # falls back to the repo the command runs in (git runs aliases at the
        # top level, but `open` need not hand that cwd to the app).
        if [ -d "$dir" ]; then
          dir=$(cd "$dir" && pwd)
        else
          dir=$PWD
        fi
        ${
          if pkgs.stdenv.isDarwin
          then ''exec open -na Ghostty --args --working-directory="$dir" -e "$bin" "$prompt"''
          else ''exec ghostty --working-directory="$dir" -e "$bin" "$prompt"''
        }
      '';
    };

    # A commit row only hands over its hash, so the branch has to be resolved
    # from the refs pointing at it. Menus cannot hide entries, so a commit with
    # no local branch reports that instead of disappearing.
    branchAt = pkgs.writeShellApplication {
      name = "sm-branch-at";
      runtimeInputs = [pkgs.git pkgs.wt pkgs.unstable.gh];
      text = ''
        # sm-branch-at <commit> <name|land|push|browse|pr>
        commit=''${1:?commit}
        verb=''${2:?verb}

        branches=$(git for-each-ref --format='%(refname:short)' --points-at "$commit" refs/heads)
        count=0
        [ -n "$branches" ] && count=$(printf '%s\n' "$branches" | wc -l)
        case $count in
          0) echo "sm-branch-at: no local branch points at $commit" >&2; exit 1 ;;
          1) ;;
          *)
            echo "sm-branch-at: several branches point at $commit; use the Locations tab:" >&2
            printf '%s\n' "$branches" | sed 's/^/  /' >&2
            exit 1
            ;;
        esac
        branch=$branches

        case $verb in
          name) printf '%s\n' "$branch" ;;
          land) exec wt land "$branch" ;;
          push) exec git push --force-with-lease origin "$branch" ;;
          browse) exec gh browse --branch "$branch" ;;
          pr) exec gh pr create --fill --head "$branch" ;;
          *) echo "sm-branch-at: unknown verb '$verb'" >&2; exit 2 ;;
        esac
      '';
    };

    agentMenu = dir: prompt: {
      caption = "Agent";
      children = [
        (run "Review in pi" ["sm-agent" "pi" dir prompt])
        (run "Review in Claude" ["sm-agent" "claude" dir prompt])
        (run "Review in Claude (work)" ["sm-agent" "claude-work" dir prompt])
      ];
    };

    # HEAD plus the working tree: what you are about to amend or push. The
    # palette has no tab context, so "." resolves to the repo it runs in.
    reviewHead = "Review the current HEAD commit together with the uncommitted changes on top of it, untracked files included. Report bugs, risky changes and missing tests.";

    commands = [
      (run "Git: Fetch All Prune" ["fetch" "--all" "--prune"])
      (run "Git: Force Push (with lease)" ["push" "--force-with-lease"])
      (run "Git: Commit Fixup for Commit…" ["commit" "--fixup=$select_commit"])
      # `sequence.editor=true` keeps the todo file autosquash generates, so the
      # whole thing runs without an editor the app would have to provide.
      (run "Git: Autosquash Rebase onto Branch…" [
        "-c"
        "sequence.editor=true"
        "rebase"
        "-i"
        "--autosquash"
        "$select_branch"
      ])
      (run "Git: Range Diff against Branch…" ["range-diff" "$select_branch...HEAD"])
      (run "Worktree: Land This Worktree" ["sm-land"])
      (run "Worktree: Clean Landed Worktrees" ["sm-clean"])
      (run "Worktree: Show Archived Work" ["sm-trash"])
      (run "Stack: Submit (auto titles)" ["sm-submit"])
      (run "Stack: Sync" ["sm-sync"])
      (run "Stack: View" ["sm-view"])
      (run "PR: Open in Browser" ["sm-pr"])
      (run "Repo: Format (just fmt)" ["sm-fmt"])
      # Palette commands cannot nest, so the agent gets one entry per front-end.
      (run "Agent: Review HEAD + Uncommitted in pi" ["sm-agent" "pi" "." reviewHead])
      (run "Agent: Review HEAD + Uncommitted in Claude" ["sm-agent" "claude" "." reviewHead])
      (run "Agent: Review HEAD + Uncommitted in Claude (work)" ["sm-agent" "claude-work" "." reviewHead])
    ];

    # Menu entries append below the shipped ones; context menus run commands
    # directly, so these use aliases rather than selectors.
    branchMenu = [
      (run "Land $branch with wt" ["sm-land" "$branch"])
      (run "Push $branch (force with lease)" ["push" "--force-with-lease" "origin" "$branch"])
      (run "Open $branch on GitHub" ["sm-browse-branch" "$branch"])
      (run "Create PR for $branch (fill)" ["sm-pr-create" "$branch"])
      (agentMenu "$working_dir" "Review branch $branch: compare it with its base and report bugs, risky changes and missing tests.")
    ];

    commitMenu = [
      (run "Fixup Staged Changes into This Commit" ["commit" "--fixup=$commit"])
      (run "Open Commit on GitHub" ["sm-browse-commit" "$commit"])
      {
        caption = "Branch at This Commit";
        children = [
          (run "Land with wt" ["sm-branch-at" "$commit" "land"])
          (run "Push (force-with-lease)" ["sm-branch-at" "$commit" "push"])
          (run "Open on GitHub" ["sm-branch-at" "$commit" "browse"])
          (run "Create PR (fill)" ["sm-branch-at" "$commit" "pr"])
        ];
      }
      (agentMenu "$working_dir" "Review commit $short_commit: show its diff, then report bugs, risky changes and missing tests.")
    ];

    worktreeMenu = [
      {
        caption = "Open in Terminal";
        command = "open_terminal";
        args = {dir = "$worktree_path";};
      }
      {
        caption = "Copy Worktree Path";
        command = "copy_to_clipboard";
        args = {text = "$worktree_path";};
      }
      (run "Land $worktree_name with wt" ["sm-land" "$worktree_name"])
      (run "Remove $worktree_name with wt (archives work)" ["sm-remove" "$worktree_name"])
      (agentMenu "$worktree_path" "Review the changes in worktree $worktree_name and report bugs, risky changes and missing tests.")
    ];

    # `primary` is ctrl on Linux, cmd on macOS. Everything else stays on the
    # command palette, whose search is faster than a binding nobody remembers.
    keymap = [
      {
        keys = ["primary+alt+l"];
        command = "git";
        args.argv = ["sm-land"];
      }
      {
        keys = ["primary+alt+s"];
        command = "git";
        args.argv = ["sm-submit"];
      }
      {
        keys = ["primary+alt+y"];
        command = "git";
        args.argv = ["sm-sync"];
      }
    ];

    settings = {
      # font_face and font_size only take effect from User preferences; the
      # Default package overrides them per platform.
      font_face = config.fireproof.theme.font.monoFamily;
      font_size = 10;
      diff_style = "auto";
      # One window per repository, so two worktrees can be read side by side.
      open_files_in_new_window = "always";
      highlight_modified_tabs = true;
      # Backs the built-in Open Repository in Terminal.
      terminal_command = "${lib.getExe config.programs.ghostty.package} --working-directory=$dir";
    };
  in {
    config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.dev.enable) {
      # darwin installs the cask (above); the nixpkgs build is Linux-only.
      home.packages = lib.optionals pkgs.stdenv.isLinux [
        pkgs.unstable.sublime-merge
      ];

      # force: the app creates these itself on first run, and home-manager
      # otherwise refuses to replace a file it does not own.
      home.file = {
        "${userDir}/Preferences.sublime-settings" = {
          force = true;
          text = builtins.toJSON settings;
        };
        "${userDir}/Default.sublime-commands" = {
          force = true;
          text = builtins.toJSON commands;
        };
        "${userDir}/Default.sublime-keymap" = {
          force = true;
          text = builtins.toJSON keymap;
        };
        "${userDir}/Branch.sublime-menu".text = builtins.toJSON branchMenu;
        "${userDir}/Commit.sublime-menu".text = builtins.toJSON commitMenu;
        "${userDir}/Worktree.sublime-menu".text = builtins.toJSON worktreeMenu;
      };

      # The menus' only exec channel is `git`, so launchers built in this module
      # get their aliases here rather than next to the other sm-* ones.
      programs.git.settings.alias = {
        sm-agent = "!${lib.getExe agentLauncher}";
        sm-branch-at = "!${lib.getExe branchAt}";
      };
    };
  };
}
