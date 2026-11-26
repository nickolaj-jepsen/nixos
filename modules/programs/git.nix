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
        alias.fixup = "!git log -n 50 --pretty=format:'%h %s' --no-merges | ${lib.getExe pkgs.fzf} | cut -c -7 | xargs -o git commit --fixup";
      };
      # pi's background tasks write their output into the checkout, and untracked
      # files there would ride into the wip commit `wt close` makes of a worktree.
      # The four root-anchored `.agents/` links are retired (the notes plugin ignores
      # `.agents/store` in each repository itself); drop these entries once old links
      # are cleaned out of every checkout.
      ignores = ["**/.claude/settings.local.json" "**/.pi/tasks/" "/.agents/store" "/.agents/workflows" "/.agents/tmp" "/.agents/claude-memory"];
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
