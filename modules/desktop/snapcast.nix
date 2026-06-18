{
  flake.modules.nixos.snapcast = {
    config,
    lib,
    ...
  }: let
    cfg = config.fireproof.desktop.snapcast;
    fifo = "/run/snapcast-fifo";

    mkLoopback = name: target: description: {
      name = "libpipewire-module-loopback";
      args = {
        "node.description" = description;
        "capture.props" = {
          "node.target" = cfg.captures.${name}.source;
          "stream.dont-remix" = true;
        };
        "playback.props" = {
          "node.target" = target;
          "media.class" = "Stream/Output/Audio";
        };
      };
    };

    captureModules = lib.flatten (lib.mapAttrsToList (name: capture:
      [(mkLoopback name cfg.sinkName "Snapcast capture: ${name}")]
      ++ lib.optional (capture.monitor != null)
      (mkLoopback name capture.monitor "Snapcast monitor: ${name}"))
    cfg.captures);
  in {
    options.fireproof.desktop.snapcast = {
      sinkName = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = "snapcast";
        description = ''
          PipeWire `node.name` of the virtual sink that feeds snapserver.
          Reference this from other modules to route audio into the stream
          (e.g. as the `playback.props."node.target"` of a loopback module).
        '';
      };
      captures = lib.mkOption {
        default = {};
        description = ''
          Audio sources to forward into the snapcast stream. Each entry creates
          a PipeWire loopback from the named source into the snapcast sink, and
          optionally a second loopback into a local monitor sink.
        '';
        type = lib.types.attrsOf (lib.types.submodule {
          options = {
            source = lib.mkOption {
              type = lib.types.str;
              description = ''
                PipeWire `node.target` of the source to capture from
                (e.g. `alsa_input.usb-Burr-Brown_from_TI_USB_Audio_CODEC-00.analog-stereo`).
              '';
            };
            monitor = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = ''
                Optional PipeWire `node.target` of a sink to also play the
                captured audio to (for local monitoring). When null, audio is
                only streamed to snapcast.
              '';
            };
          };
        });
      };
    };

    config = lib.mkIf config.fireproof.desktop.snapcast.enable {
      systemd.tmpfiles.rules = [
        "p ${fifo} 0666 root root - "
      ];

      services.pipewire.extraConfig.pipewire."99-snapcast" = {
        "context.modules" =
          [
            {
              name = "libpipewire-module-pipe-tunnel";
              args = {
                "tunnel.mode" = "sink";
                "pipe.filename" = fifo;
                "audio.format" = "S16LE";
                "audio.rate" = 48000;
                "audio.channels" = 2;
                "audio.position" = ["FL" "FR"];
                "stream.props" = {
                  "node.name" = cfg.sinkName;
                  "node.description" = "Snapcast";
                };
              };
            }
          ]
          ++ captureModules;
      };

      services.snapserver = {
        enable = true;
        openFirewall = true;
        settings = {
          stream = {
            source = "pipe://${fifo}?name=default&mode=read&sampleformat=48000:16:2&codec=flac";
          };
          tcp.enabled = true;
          http.enabled = true;
        };
      };
    };
  };
}
