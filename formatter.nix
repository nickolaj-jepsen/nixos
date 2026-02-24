{
  inputs,
  lib,
  ...
}: let
  mkExtensionIgnore = exts: "*.{${lib.concatStringsSep "," exts}}";
in {
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
        fish_indent.enable = true;
      };
      settings.global.excludes = [
        "result"
        ".github/workflows/*.lock.yml"
        (mkExtensionIgnore [
          "gitignore"
          "age"
          "pub"
          "svg"
        ])
      ];
    };
    formatter = config.treefmt.build.wrapper;
  };
}
