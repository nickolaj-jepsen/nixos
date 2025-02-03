{mylib, ...}: {
  perSystem = {system, ...}: {
    packages.vm = mylib.mkVm [
      ./modules/base.nix
      ./modules/graphical.nix
      {
        user.username = "vm";
        system.stateVersion = "24.11";
        monitor.primary.resolution = "1920x1080";
        services.qemuGuest.enable = true;
        services.spice-vdagentd.enable = true;
      }
    ];
  };
}
