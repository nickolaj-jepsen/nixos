{pkgs, ...}: {
  fireproof.home-manager = {
    home.packages = [pkgs.unstable.jjui];

    programs.jujutsu = {
      enable = true;
      package = pkgs.unstable.jujutsu;

      settings = {
        user = {
          email = "nickolaj@fireproof.website";
          name = "Nickolaj Jepsen";
        };
      };
    };
  };
}
