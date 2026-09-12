{
  nixos = {
    wsl.usbip.autoAttach = ["1-10"]; # YubiKey; usbipd busids are per-port
    system.stateVersion = "25.11";
  };
}
