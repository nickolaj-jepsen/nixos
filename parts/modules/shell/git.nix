{pkgs, ...}: {
  environment.systemPackages = with pkgs; [
    git
    pre-commit
  ];

  fireproof.home-manager.programs.git = {
    enable = true;
    userEmail = "nickolaj@fireproof.website";
    userName = "Nickolaj Jepsen";
    includes = [
      {
        condition = "hasconfig:remote.*.url:*Digital-Udvikling*";
        contents = {
          user.email = "nij@ao.dk";
        };
      }
    ];
  };
}
