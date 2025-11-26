{pkgsUnstable, ...}: {
  environment.systemPackages = with pkgsUnstable; [
    jujutsu
    jjui
  ];

  fireproof.home-manager.programs.jujutsu = {
    enable = true;

    settings = {
      user = {
        email = "nickolaj@fireproof.website";
        name = "Nickolaj Jepsen";
      };
    };
  };
}
