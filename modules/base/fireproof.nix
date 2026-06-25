# Cross-class fireproof.* options, emitted to both nixos and home-manager so either eval reads them locally (no osConfig bridge).
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

      # GUI apps decoupled from desktop.enable so a non-desktop host (macbook) can opt in.
      firefox.enable = lib.mkOption {
        type = lib.types.bool;
        default = config.fireproof.desktop.enable;
        description = "Firefox with an HM-managed profile; on darwin the binary is a Homebrew cask (package = null) and HM manages config only.";
      };
      vscode.enable = lib.mkOption {
        type = lib.types.bool;
        default = config.fireproof.desktop.enable && config.fireproof.dev.enable;
        description = "VSCode with HM-managed settings/extensions (nixpkgs build); mac-app-util surfaces the .app on darwin.";
      };
      ghostty.enable = lib.mkOption {
        type = lib.types.bool;
        default = config.fireproof.desktop.enable;
        description = "Ghostty terminal with HM-managed config/theme; on darwin the binary is a Homebrew cask (package = null) and HM manages config only.";
      };
      karabiner.enable = lib.mkEnableOption "Karabiner-Elements key remapping (darwin) — installs the cask and deploys a Nix-generated karabiner.json that ports the keyd/Linux keybindings";

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
        k8s.enable = lib.mkOption {
          type = lib.types.bool;
          default = config.fireproof.dev.enable;
          description = "Enable kubectl and the AO kube configs";
        };
        mcp.enable = lib.mkOption {
          type = lib.types.bool;
          default = config.fireproof.dev.enable;
          description = "Enable MCP servers (incl. the grafana env-wrapper secret)";
        };
      };

      neovim.full.enable = lib.mkOption {
        type = lib.types.bool;
        default = config.fireproof.dev.enable;
        description = ''
          Layer the heavy neovim language support (pyrefly/TS/web LSPs + their
          tree-sitter grammars, nixd) on top of the always-on lean baseline.
          Defaults to dev.enable; override off to keep the editor lean.
        '';
      };

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

      # Cross-class fact read by home-manager halves. See: https://github.com/ChangeCaps/nixos-config
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
            # When unset on every entry, consumers fall back to the first active entry (fpLib.primaryMonitor).
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
  # Emitted to darwin too so shared cards' fireproof.* facts type-check there.
  flake.modules.darwin.fireproof-options = sharedOptions;
}
