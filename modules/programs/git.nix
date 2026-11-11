{
  flake.modules.homeManager.git = {
    pkgs,
    lib,
    ...
  }: {
    programs.gh = {
      enable = true;
      package = pkgs.unstable.gh;
      extensions = [
        pkgs.unstable.gh-poi
        pkgs.unstable.gh-dash
        pkgs.unstable.gh-stack
      ];
      settings.git_protocol = "ssh";
    };

    # Upstream ships the agent skill in the extension's source, so it always
    # matches the installed version. fetchTarball, not `.src` (same store path):
    # the agent modules pathIsDirectory-check skills, which is IFD on a derivation.
    fireproof.agents.skills.gh-stack = let
      inherit (pkgs.unstable.gh-stack) src;
    in "${builtins.fetchTarball {
      inherit (src) url;
      sha256 = src.outputHash;
    }}/skills/gh-stack";

    # Git worktrees for parallel agents (worktrunk.dev). Shell integration is in
    # the fish leaf, the Claude Code plugin in the claude-code leaf. Existing
    # worktrees keep the ~/worktrees/<repo>/<branch> layout, and a merge
    # rebases and fast-forwards what is committed, without squashing or
    # committing stray changes. No LLM runs: that needs a [commit.generation]
    # command, and the skipped prompt would offer to set one up (and write this
    # read-only file).
    home.packages = [pkgs.unstable.worktrunk];
    xdg.configFile."worktrunk/config.toml".text = ''
      worktree-path = "~/worktrees/{{ repo }}/{{ branch | sanitize }}"
      skip-shell-integration-prompt = true
      skip-commit-generation-prompt = true

      [merge]
      squash = false
      commit = false
    '';
    fireproof.agents.skills.worktrunk = let
      inherit (pkgs.unstable.worktrunk) src;
    in "${builtins.fetchTarball {
      inherit (src) url;
      sha256 = src.outputHash;
    }}/skills/worktrunk";

    programs.delta = {
      enable = true;
      enableGitIntegration = true;
    };

    # A named difftool only (`git difftool -t difft`): its git integration sets
    # diff.external, which breaks anything that parses `git diff`.
    programs.difftastic.enable = true;

    programs.git = {
      enable = true;

      settings = {
        user.email = "nickolaj@fireproof.website";
        user.name = "Nickolaj Jepsen";
        push.autosetupremote = "true";
        pull.rebase = "true";
        rebase.autosquash = "true";
        rebase.autoStash = "true";
        # gh-stack passes rebase.updateRefs=false to its own rebases, so this only moves stacks in a manual rebase.
        rebase.updateRefs = true;
        rerere.enabled = true;
        init.defaultBranch = "main";
        merge.conflictStyle = "zdiff3";
        diff.algorithm = "histogram";
        diff.colorMoved = "default";
        difftool.difft.cmd = "${lib.getExe pkgs.difftastic} \"$LOCAL\" \"$REMOTE\"";
        # Not pruneTags: it would delete local tags that were never pushed.
        fetch.prune = true;
        push.followTags = true;
        branch.sort = "-committerdate";
        tag.sort = "version:refname";
        column.ui = "auto";
        # The fish prompt's `git status` runs with --no-optional-locks, so other git commands keep this cache fresh.
        core.untrackedCache = true;
        # Linux git has no builtin fsmonitor daemon.
        core.fsmonitor = pkgs.stdenv.hostPlatform.isDarwin;
        # Clone, checkout and `git worktree add` all fire this. Config-based hooks
        # run beside a repository's own post-checkout rather than replacing it,
        # and the command is quiet and idempotent because git hands its exit
        # status back to the checkout that ran it. Git older than 2.54 ignores
        # the section; the agents' wrappers repair the links at startup.
        hook.agent-notes = {
          event = "post-checkout";
          command = "${lib.getExe pkgs.agent-notes} init";
        };
        alias = {
          fixup = "!git log -n 50 --pretty=format:'%h %s' --no-merges | ${lib.getExe pkgs.fzf} | cut -c -7 | xargs -o git commit --fixup";
          # Wrappers for non-git tools, because Sublime Merge's custom commands can
          # only run `git` argv (see modules/programs/sublime-merge.nix). Absolute
          # paths: the GUI process has no shell PATH of its own. `sm-merge` lands a
          # worktree by path (`wt merge` takes no source branch), `sm-remove` takes a
          # path or branch; both default to the worktree the command runs in. A
          # function, since git appends an alias's arguments to its command line.
          sm-merge = "!f() { ${lib.getExe pkgs.unstable.worktrunk} -C \"\${1:-.}\" merge --no-commit; }; f";
          sm-remove = "!f() { ${lib.getExe pkgs.unstable.worktrunk} remove \"\${1:-@}\"; }; f";
          sm-submit = "!${lib.getExe pkgs.unstable.gh} stack submit --auto";
          sm-sync = "!${lib.getExe pkgs.unstable.gh} stack sync";
          sm-view = "!${lib.getExe pkgs.unstable.gh} stack view";
          sm-pr = "!${lib.getExe pkgs.unstable.gh} pr view --web";
          sm-pr-create = "!${lib.getExe pkgs.unstable.gh} pr create --fill --head \"$1\"";
          sm-browse-branch = "!${lib.getExe pkgs.unstable.gh} browse --branch \"$1\"";
          sm-browse-commit = "!${lib.getExe pkgs.unstable.gh} browse --commit \"$1\"";
          sm-fmt = "!${lib.getExe pkgs.unstable.just} fmt";
        };
      };
      # pi's background tasks write their output into the checkout, where untracked
      # files would make a worktree dirty, which `wt remove` refuses.
      # The agent-notes links are root-anchored, so a nested `.agents/` does not match.
      ignores = ["**/.claude/settings.local.json" "**/.pi/tasks/" "/.agents/store" "/.agents/tmp"];
      includes = [
        {
          condition = "hasconfig:remote.*.url:git@github.com:Digital-Udvikling/**";
          contents = {
            user.email = "nij@ao.dk";
          };
        }
      ];
    };
    # Replaces the hand-written file this list grew out of.
    xdg.configFile."git/ignore".force = true;
  };
}
