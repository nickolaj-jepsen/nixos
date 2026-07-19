{
  # The FiiO E10K is a full-speed USB device behind a high-speed hub shared with
  # several HID receivers. When WirePlumber suspends the idle sink, the audio
  # altsetting's isochronous bandwidth is released and re-reserving it on the
  # hub's transaction translator fails ("Not enough bandwidth for altsetting 1"),
  # leaving playback crackling until replug. Keep the stream open instead.
  nixos = {
    services.pipewire.wireplumber.extraConfig."51-fiio-no-suspend" = {
      "monitor.alsa.rules" = [
        {
          matches = [{"node.name" = "alsa_output.usb-FiiO_DigiHug_USB_Audio-01.analog-stereo";}];
          actions.update-props = {
            "session.suspend-timeout-seconds" = 0;
          };
        }
      ];
    };
  };
}
