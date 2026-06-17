# Selection (aspects + facts) lives in hosts/default.nix.
{
  config = {
    wsl.usbip.autoAttach = ["1-9"];

    system.stateVersion = "25.11";
  };
}
