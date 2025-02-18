{
  hostname,
  version,
  inputs,
  ...
}: let
  username = "vm";
in {
  perSystem = {
    system,
    pkgs,
    ...
  }: {
    packages.vm = inputs.nixos-generators.nixosGenerate {
      specialArgs = {
        inherit inputs system pkgs hostname version username;
      };

      modules = [
        inputs.home-manager.nixosModules.home-manager
        inputs.agenix.nixosModules.default
        inputs.agenix-rekey.nixosModules.default
        ./modules/base/user.nix
        ./modules/required.nix
        ./modules/shell.nix
        ./modules/graphical.nix
        {
          users.users.${username} = {
            isNormalUser = true;
            extraGroups = ["wheel" "networkmanager" "libvirt" "kvm"];
          };
          monitors = [{resolution="1920x1080";}];
          services.qemuGuest.enable = true;
          services.spice-vdagentd.enable = true;
        }
      ];
      inherit system;
      format = "qcow";
    };
  };
}
