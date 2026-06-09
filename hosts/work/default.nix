{lib, ...}: {
  config = {
    fireproof = {
      hostname = "work";
      username = "nickolaj";
      desktop.enable = true;
      work.enable = true;
      dev.enable = true;
      claude-code.work.enable = true;
      hardware.nvidia.enable = true;
    };
    facter.reportPath = ./facter.json;

    # aarch64 emulation so this x86_64 host can cross-build the Raspberry Pi
    # kiosk SD image (~/dev/kiosk). Some derivations run target binaries at
    # build time (e.g. writeShellScript's bash -n), which fails without binfmt.
    boot.binfmt.emulatedSystems = ["aarch64-linux"];

    fireproof.home-manager.programs.firefox.profiles.default.settings."browser.startup.homepage" = lib.mkForce "https://glance.nickolaj.com/work";
  };
}
