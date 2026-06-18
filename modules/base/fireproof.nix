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
  }: {
    options.fireproof = {
      hostname = lib.mkOption {
        type = lib.types.str;
        description = "The hostname of the machine";
      };
      username = lib.mkOption {
        type = lib.types.str;
        default = "nickolaj";
        description = "The primary username for the machine";
      };

      work.enable = lib.mkEnableOption "work-related applications and tools";

      # Desktop capability + its opt-in sub-features: chromium cascades off
      # desktop.enable; the rest default off (bambu-studio, google-chrome,
      # snapcast, oxcbMedia). The matching leaf also declares the non-enable
      # knobs (snapcast.captures, oxcbMedia.*).
      desktop = {
        enable = lib.mkEnableOption "desktop environment with niri, greetd, and all desktop features";
        chromium.enable = lib.mkOption {
          type = lib.types.bool;
          default = config.fireproof.desktop.enable;
          description = "Enable the Chromium browser";
        };
        bambu-studio.enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Enable Bambu Studio 3D printing slicer";
        };
        google-chrome.enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Enable Google Chrome";
        };
        snapcast.enable = lib.mkEnableOption "Snapcast audio streaming server";
        oxcbMedia.enable = lib.mkEnableOption "0xCB-media host daemon (bridges MPRIS + PipeWire to the 0xCB-1337 macropad over USB CDC ACM)";
      };

      claude-code.work.enable =
        lib.mkEnableOption "claude-work wrapper sharing the personal claude-code config via ~/.claude-work";

      # Development capability; its IDE/tooling sub-features cascade off dev.enable.
      dev = {
        enable = lib.mkEnableOption "development tools and applications";
        intellij.enable = lib.mkOption {
          type = lib.types.bool;
          default = config.fireproof.dev.enable;
          description = "Enable IntelliJ-based IDEs";
        };
        clickhouse.enable = lib.mkOption {
          type = lib.types.bool;
          default = config.fireproof.dev.enable;
          description = "Enable Clickhouse";
        };
        playwright.enable = lib.mkOption {
          type = lib.types.bool;
          default = config.fireproof.dev.enable;
          description = "Enable Playwright";
        };
      };

      # systemd-networkd wired networking — a dendritic-branch deviation from
      # main, kept intentionally.
      networkd.enable = lib.mkEnableOption "systemd-networkd wired networking";
      wsl.enable = lib.mkEnableOption "WSL configuration";

      homelab = {
        enable = lib.mkEnableOption "homelab server services (arr, jellyfin, nginx, …)";
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
        physical = lib.mkOption {
          type = lib.types.bool;
          default = !config.fireproof.wsl.enable;
          description = "Whether this is a physical machine (not WSL/VM). Enables baseline hardware hygiene: SMART monitoring, thermald, zram, btrfs scrub and journald caps.";
        };
        zram = lib.mkOption {
          type = lib.types.bool;
          default = config.fireproof.hardware.physical;
          description = "Enable compressed RAM swap (zram) for memory-pressure headroom without writing to disk.";
        };
        nvidia.enable = lib.mkEnableOption "NVIDIA GPU support (open kernel module + VA-API video offload)";
        laptop = lib.mkEnableOption "laptop-specific configurations and tools";
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
    };
  };
in {
  flake.modules.nixos.fireproof-options = sharedOptions;
  flake.modules.homeManager.fireproof-options = sharedOptions;
}
