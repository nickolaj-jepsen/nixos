{
  nixos = {
    wsl.usbip.autoAttach = ["1-9"];
    system.stateVersion = "25.11";
  };
}
