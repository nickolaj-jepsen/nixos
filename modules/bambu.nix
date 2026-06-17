{
  flake.modules.homeManager.bambu-studio = {pkgs, ...}: {
    config = {
      home.packages = [
        pkgs.bambu-studio
      ];
    };
  };
}
