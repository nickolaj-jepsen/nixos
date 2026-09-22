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
        pkgs.gh-aw
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
        gpg.format = "ssh";
        push.autosetupremote = "true";
        pull.rebase = "true";
        rebase.autosquash = "true";
        rebase.autoStash = "true";
        rerere.enabled = true;
        init.defaultBranch = "main";
        alias.fixup = "!git log -n 50 --pretty=format:'%h %s' --no-merges | ${lib.getExe pkgs.fzf} | cut -c -7 | xargs -o git commit --fixup";
      };
      includes = [
        {
          condition = "hasconfig:remote.*.url:git@github.com:Digital-Udvikling/**";
          contents = {
            user.email = "nij@ao.dk";
          };
        }
      ];
    };
  };
}
