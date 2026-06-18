# Shared fireproof.* option declarations, emitted to BOTH the nixos and the
# home-manager module classes so either eval can read them locally — this is
# what removes the need for an osConfig bridge. Only the cross-class subset
# lives here; feature-local, single-class options stay colocated in their leaf.
#
# Dendritic self-declaring module: the import-tree shim passes it through
# because it sets `flake.*` directly (see flake.nix).
let
  sharedOptions = {
    config,
    lib,
    ...
  }: let
    mkColorOption = default: description:
      lib.mkOption {
        type = lib.types.str;
        inherit default description;
        example = default;
      };
  in {
    options.fireproof = {
      hostname = lib.mkOption {
        type = lib.types.str;
        description = "The hostname of the machine";
      };
      username = lib.mkOption {
        type = lib.types.str;
        description = "The primary username for the machine";
      };

      work.enable = lib.mkEnableOption "Enable work-related applications and tools";

      desktop.enable = lib.mkEnableOption "Enable desktop environment with niri, greetd, and all desktop features";

      claude-code.work.enable =
        lib.mkEnableOption "claude-work wrapper sharing the personal claude-code config via ~/.claude-work";

      homelab = {
        domain = lib.mkOption {
          type = lib.types.str;
          default = "nickolaj.com";
          description = "Root domain used for homelab service hostnames.";
        };
        acmeEmail = lib.mkOption {
          type = lib.types.str;
          default = "nickolaj@fireproof.website";
          description = "Contact email registered with the ACME provider.";
        };
      };

      hardware = {
        laptop = lib.mkEnableOption "Enable laptop-specific configurations and tools";
        gpuPciId = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "10de:2c05";
          description = ''
            PCI id of a discrete GPU to surface in DMS GPU widgets (bar gpuTemp +
            system-monitor GPU temperature). Must match the id dgop reports
            (`dgop gpu --json` -> .gpus[].pciId), not the sysfs bus address.
            null disables the GPU widgets.
          '';
        };
        battery = lib.mkOption {
          type = lib.types.bool;
          default = config.fireproof.hardware.laptop;
          description = "Enable battery support (UPower, battery widget, etc.)";
        };
        wifi = lib.mkOption {
          type = lib.types.bool;
          default = config.fireproof.hardware.laptop;
          description = "Enable WiFi support (NetworkManager, wireless tools, etc.)";
        };
        dimmableBacklight = lib.mkOption {
          type = lib.types.bool;
          default = config.fireproof.hardware.laptop;
          description = "Enable dimmable backlight support (brightnessctl, backlight widget, etc.)";
        };
      };

      # Per-output display configuration, consumed by niri/outputs and the DMS
      # bar/widgets. A cross-class fact (read by home-manager halves), set per
      # host. See: https://github.com/ChangeCaps/nixos-config
      monitors = lib.mkOption {
        default = [];
        description = "Per-output display configuration.";
        type = lib.types.listOf (lib.types.submodule {
          options = {
            name = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              example = "DP-1";
            };
            resolution.width = lib.mkOption {
              type = lib.types.nullOr lib.types.int;
              default = null;
            };
            resolution.height = lib.mkOption {
              type = lib.types.nullOr lib.types.int;
              default = null;
            };
            refreshRateNiri = lib.mkOption {
              type = lib.types.nullOr lib.types.float;
              default = null;
              example = 60.0;
            };
            position.x = lib.mkOption {
              type = lib.types.int;
              default = 0;
            };
            position.y = lib.mkOption {
              type = lib.types.int;
              default = 0;
            };
            scale = lib.mkOption {
              type = lib.types.float;
              default = 1.0;
            };
            transform = lib.mkOption {
              type = lib.types.nullOr lib.types.int;
              default = null;
              example = 1;
            };
            enable = lib.mkOption {
              type = lib.types.bool;
              default = true;
            };
            # Marks the primary monitor. When no entry is flagged, consumers fall
            # back to the first (active) entry in list order. See fpLib.primaryMonitor.
            primary = lib.mkOption {
              type = lib.types.bool;
              default = false;
            };
          };
        });
      };

      theme = {
        # Flexoki-inspired palette. See: https://stephango.com/flexoki
        colors = {
          bg = mkColorOption "1C1B1A" "Primary background color";
          bgAlt = mkColorOption "282726" "Alternative background color";

          fg = mkColorOption "DAD8CE" "Primary foreground/text color";
          fgAlt = mkColorOption "B7B5AC" "Alternative foreground color";

          muted = mkColorOption "878580" "Muted/disabled text color";
          ui = mkColorOption "343331" "UI element background";
          uiAlt = mkColorOption "403E3C" "Alternative UI element background";

          black = mkColorOption "100F0F" "Black (darkest)";
          white = mkColorOption "DAD8CE" "White (same as fg)";
          whiteAlt = mkColorOption "F2F0E5" "Bright white";

          accent = mkColorOption "CF6A4C" "Primary accent color";
          accentContainer = mkColorOption "6B3528" "Dark container tone derived from accent";

          red = mkColorOption "D14D41" "Red (errors, destructive)";
          redAlt = mkColorOption "AF3029" "Dark red";
          orange = mkColorOption "DA702C" "Orange (warnings)";
          orangeAlt = mkColorOption "BC5215" "Dark orange";
          yellow = mkColorOption "D0A215" "Yellow (caution)";
          yellowAlt = mkColorOption "AD8301" "Dark yellow";
          green = mkColorOption "879A39" "Green (success)";
          greenAlt = mkColorOption "66800B" "Dark green";
          cyan = mkColorOption "3AA99F" "Cyan";
          cyanAlt = mkColorOption "24837B" "Dark cyan";
          blue = mkColorOption "4385BE" "Blue (info, links)";
          blueAlt = mkColorOption "205EA6" "Dark blue";
          purple = mkColorOption "8B7EC8" "Purple";
          purpleAlt = mkColorOption "5E409D" "Dark purple";
          magenta = mkColorOption "CE5D97" "Magenta";
          magentaAlt = mkColorOption "A02F6F" "Dark magenta";
        };
      };
    };
  };
in {
  flake.modules.nixos.fireproof-options = sharedOptions;
  flake.modules.homeManager.fireproof-options = sharedOptions;
}
