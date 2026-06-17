# Selection (aspects + facts) lives in hosts/default.nix. This file holds only
# minilab's nixos-specific settings (snapcast turntable capture, oxcb macropad).
{
  config = {
    fireproof.desktop = {
      snapcast = {
        enable = true;
        captures.turntable = {
          source = "alsa_input.usb-Burr-Brown_from_TI_USB_Audio_CODEC-00.analog-stereo-input";
          monitor = "alsa_output.pci-0000_00_0e.0.analog-stereo";
        };
      };
      oxcbMedia.enable = true;
    };

    facter.reportPath = ./facter.json;
  };
}
