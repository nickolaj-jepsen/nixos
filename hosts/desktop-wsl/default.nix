{
  config = {
    fireproof = {
      hostname = "desktop-wsl";
      username = "nickolaj";
      work.enable = true;
      dev.enable = true;
      wsl.enable = true;
    };

    system.stateVersion = "25.11";
  };

  imports = [
    ./ssh.nix
  ];
}
