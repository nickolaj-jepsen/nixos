{lib, ...}: {
  config = {
    fireproof = {
      hostname = "work";
      username = "nickolaj";
      desktop.enable = true;
      work.enable = true;
      dev.enable = true;
    };
    facter.reportPath = ./facter.json;

    fireproof.home-manager.programs.firefox.profiles.default.settings."browser.startup.homepage" = lib.mkForce "https://glance.nickolaj.com/work";
  };

  imports = [
    ./bluetooth.nix
    ./disk-configuration.nix
    ./monitors.nix
    ./networking.nix
    ./nvidia.nix
    ./ssh.nix
  ];
}
