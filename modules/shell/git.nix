{pkgs, lib, ...}: {
  environment.systemPackages = with pkgs; [
    git
    gh
    pre-commit
  ];

  fireproof.home-manager.programs.git = {
    enable = true;

    userEmail = "nickolaj@fireproof.website";
    userName = "Nickolaj Jepsen";

    extraConfig = {
      gpg.format = "ssh";
      gpg.ssh.program = "op-ssh-sign";
      push.autosetupremote = "true";
      pull.rebase = "true";
      rebase.autosqush = "true";
      rerere.enabled = true;
      init.defaultBranch = "main";
    };

    delta.enable = true;

    aliases = {
      "fixup" = "!git log -n 50 --pretty=format:'%h %s' --no-merges | ${lib.getExe pkgs.fzf} | cut -c -7 | xargs -o git commit --fixup";
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
