{
  pkgs,
  lib,
  ...
}: {
  environment.systemPackages = with pkgs; [
    git
    gh
    pre-commit
  ];

  fireproof.home-manager.programs.delta = {
    enable = true;
    enableGitIntegration = true;
  };

  fireproof.home-manager.programs.git = {
    enable = true;

    settings = {
      user.email = "nickolaj@fireproof.website";
      user.name = "Nickolaj Jepsen";
      gpg.format = "ssh";
      gpg.ssh.program = "op-ssh-sign";
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
}
