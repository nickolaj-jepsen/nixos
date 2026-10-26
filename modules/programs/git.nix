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

    programs.git = {
      enable = true;

      settings = {
        user.email = "nickolaj@fireproof.website";
        user.name = "Nickolaj Jepsen";
        push.autosetupremote = "true";
        pull.rebase = "true";
        rebase.autosquash = "true";
        rebase.autoStash = "true";
        rerere.enabled = true;
        init.defaultBranch = "main";
        # The fish prompt's `git status` runs with --no-optional-locks, so other git commands keep this cache fresh.
        core.untrackedCache = true;
        # Linux git has no builtin fsmonitor daemon.
        core.fsmonitor = pkgs.stdenv.hostPlatform.isDarwin;
        alias = {
          fixup = "!git log -n 50 --pretty=format:'%h %s' --no-merges | ${lib.getExe pkgs.fzf} | cut -c -7 | xargs -o git commit --fixup";
          # Wrappers for non-git tools, because Sublime Merge's custom commands can
          # only run `git` argv (see modules/programs/sublime-merge.nix). Absolute
          # paths: the GUI process has no shell PATH of its own. `sm-land` and
          # `sm-remove` default to the worktree the command runs in.
          sm-land = "!${lib.getExe pkgs.wt} land \"\${1:-.}\"";
          sm-remove = "!${lib.getExe pkgs.wt} remove \"\${1:-.}\"";
          sm-clean = "!${lib.getExe pkgs.wt} clean";
          sm-trash = "!${lib.getExe pkgs.wt} trash";
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
      # pi's background tasks write their output into the checkout, and untracked
      # files there would keep `wt clean` from sweeping a landed worktree.
      ignores = ["**/.claude/settings.local.json" "**/.pi/tasks/"];
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
