# minilab co-locates the snapcast aspect with its host-specific capture config:
# the USB turntable line-in, forwarded into the stream and mirrored to the local
# speakers.
{
  aspects = ["snapcast"];

  nixos.fireproof.desktop.snapcast.captures.turntable = {
    source = "alsa_input.usb-Burr-Brown_from_TI_USB_Audio_CODEC-00.analog-stereo-input";
    monitor = "alsa_output.pci-0000_00_0e.0.analog-stereo";
  };
}
