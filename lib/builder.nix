args @ {
  lib,
  withSystem,
  inputs,
  ...
}:
with lib; let
  inherit (import ./. args) recursiveMerge;
  mkBase = {system ? "x86_64-linux", ...}:
    withSystem system (
      {
        pkgs,
        system,
        ...
      }: {
        inherit system;
        specialArgs = {inherit inputs pkgs;};
        modules = [
          inputs.disko.nixosModules.disko
          inputs.home-manager.nixosModules.home-manager
        ];
      }
    );
  mkNixos = args:
    inputs.nixpkgs.lib.nixosSystem (recursiveMerge [
      (mkBase args)
      args
    ]);
in {
  mkHosts = root: let
    hosts = attrNames (filterAttrs (_: type: type == "directory") (builtins.readDir root));

    hostDirs = builtins.listToAttrs (
      lib.map (hostName: lib.nameValuePair hostName (lib.path.append root hostName)) hosts
    );

    hostResolved =
      lib.mapAttrs (
        _: hostDir: (lib.map (fileName: lib.path.append hostDir fileName) (attrNames (builtins.readDir hostDir)))
      )
      hostDirs;

    hostsConfig = mapAttrs (_: configs: mkNixos {modules = configs;}) hostResolved;
  in
    hostsConfig;

  mkVm = configs:
    inputs.nixos-generators.nixosGenerate {
      modules = configs;
      format = "qcow";
      system = "x86_64-linux";
    };
}
