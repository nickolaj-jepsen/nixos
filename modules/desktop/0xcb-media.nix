{inputs, ...}: {
  flake.modules.nixos.oxcb-media = {
    config,
    lib,
    ...
  }: {
    imports = [inputs.zero-x-cb-media.nixosModules.default];

    config = lib.mkIf config.fireproof.desktop.oxcbMedia.enable {
      services."0xcb-media-host".enable = true;

      users.extraGroups.dialout.members = [config.fireproof.username];
    };
  };
}
