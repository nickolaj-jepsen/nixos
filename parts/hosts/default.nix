{
  inputs,
  withSystem,
  lib,
  ...
}:
with lib; let
  mkSystem = {
    hostname,
    username,
    modules ? [],
  }:
    withSystem "x86_64-linux" (
      {
        pkgs,
        system,
        ...
      }:
        inputs.nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = {inherit inputs pkgs hostname username;};
          modules =
            [
              inputs.disko.nixosModules.disko
              inputs.home-manager.nixosModules.home-manager
            ]
            ++ [
              inputs.agenix.nixosModules.default
              inputs.agenix-rekey.nixosModules.default
              {
                environment.variables = {
                  AGENIX_REKEY_PRIMARY_IDENTITY = builtins.readFile ../../secrets/hosts/${hostname}/id_ed25519.pub;
                  AGENIX_REKEY_PRIMARY_IDENTITY_ONLY = "true";
                };
                environment.etc."ssh/ssh_host_ed25519_key.pub".source = ../../secrets/hosts/${hostname}/id_ed25519.pub;
                age = rec {
                  rekey = {
                    storageMode = "local";
                    hostPubkey = builtins.readFile ../../secrets/hosts/${hostname}/id_ed25519.pub;
                    masterIdentities = [
                      { identity=secrets.id_ed25519.path; pubkey="builtins.readFile ../../secrets/hosts/${hostname}/id_ed25519.pub"; }
                      { identity=../../secrets/yubikey-identity.age; pubkey="age1yubikey1q25a8ax2t0ujv7q5wvpmlpa52h599n6682jprxuftlw4zpxy2xu9s6lhrel"; }
                    ];
                    localStorageDir = lib.path.append ../../secrets/rekeyed hostname;
                    generatedSecretsDir = lib.path.append ../../secrets hostname;
                  };
                  secrets.hashed-user-password.rekeyFile = ../../secrets/hashed-user-password.age;
                  secrets.id_ed25519={
                    rekeyFile = ../../secrets/hosts/${hostname}/id_ed25519.age;
                    path = "/etc/ssh/ssh_host_ed25519_key";
                  };
                  secrets.luks-password.rekeyFile = ../../secrets/luks-password.age;
                  secrets.luks-password.path = "/luks-password";
                };
              }
            ]
            ++ modules;
        }
    );
  # TODO:
  # mkHosts = root: let
  #   hosts = attrNames (filterAttrs (_: type: type == "directory") (builtins.readDir root));
  #   hostDirs = builtins.listToAttrs (
  #     lib.map (hostName: lib.nameValuePair hostName (lib.path.append root hostName)) hosts
  #   );
  #   hostResolved =
  #     lib.mapAttrs (
  #       _: hostDir: (lib.map (fileName: lib.path.append hostDir fileName) (attrNames (builtins.readDir hostDir)))
  #     )
  #     hostDirs;
  #   hostsConfig = mapAttrs (host: modules: mkSystem host modules ) hostResolved;
  # in
  #   hostsConfig;
in {
  flake.nixosConfigurations = {
    laptop = mkSystem {
      hostname = "laptop";
      modules = [
        ./laptop/configuration.nix
        ./laptop/disk-configuration.nix
        ./laptop/hardware-configuration.nix
      ];
      username = "nickolaj";
    };
    desktop = mkSystem {
      hostname = "desktop";
      modules = [
        ./desktop/configuration.nix
      ];
      username = "nickolaj";
    };
  };
}
