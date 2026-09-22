{inputs, ...}: {
  flake.modules.nixos.wsl = {
    config,
    lib,
    ...
  }: {
    imports = [inputs.nixos-wsl.nixosModules.default];
    config = lib.mkIf config.fireproof.wsl.enable {
      wsl = {
        enable = true;
        defaultUser = config.fireproof.username;
        startMenuLaunchers = true;
        interop.includePath = false;
        usbip.enable = true;
      };

      # The VHD grows on every write and never shrinks; keep /tmp churn in RAM.
      boot.tmp.useTmpfs = true;

      # wsl.usbip.enable ships the tooling but never loads the driver
      boot.kernelModules = ["vhci-hcd"];
    };
  };
}
