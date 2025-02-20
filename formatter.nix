{inputs, ...}: {
  imports = [inputs.treefmt-nix.flakeModule];

  perSystem = {config, ...}: {
    treefmt = {
      projectRootFile = "flake.nix";
      programs = {
        deadnix.enable = true;
        alejandra.enable = true;
        statix.enable = true;
        just.enable = true;
        prettier.enable = true;
      };
      settings.global.excludes = ["*.{gitignore,svg}"];
    };
    formatter = config.treefmt.build.wrapper;
  };
}
