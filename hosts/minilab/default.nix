{
  config = {
    fireproof = {
      hostname = "minilab";
      username = "nickolaj";
      desktop = {
        enable = true;
        chromium.enable = false;
        snapcast = {
          enable = true;
          captures.turntable = {
            source = "alsa_input.usb-Burr-Brown_from_TI_USB_Audio_CODEC-00.analog-stereo-input";
            monitor = "alsa_output.pci-0000_00_0e.0.analog-stereo";
          };
        };
        oxcbMedia.enable = true;
      };
      dev = {
        enable = true;
        intellij.enable = false;
        clickhouse.enable = false;
        playwright.enable = false;
      };
    };

    facter.reportPath = ./facter.json;
  };
}
