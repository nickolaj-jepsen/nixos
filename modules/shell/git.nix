{pkgs, ...}: {
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
      rerere.enabled = true;
      init.defaultBranch = "main";
    };
    delta.enable = true;

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
