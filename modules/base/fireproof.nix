# Cross-class fireproof.* options, emitted to both nixos and home-manager so either eval reads them locally (no osConfig bridge).
let
  sharedOptions = {
    config,
    lib,
    ...
  }: let
    # Bool defaulting to another toggle (the cascade in docs/modules.md).
    cascade = default: description:
      lib.mkOption {
        type = lib.types.bool;
        inherit default description;
      };
  in {
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

      # Enabling a host needs `just secret-rekey` — the body is an agenix secret.
      scripts.tunnel-home.enable = lib.mkEnableOption "tunnel-home, an sshuttle wrapper for reaching a remote network over SSH";

      desktop = {
        enable = lib.mkEnableOption "desktop environment with niri, greetd, and all desktop features";
        chromium = {
          enable = cascade config.fireproof.desktop.enable "Enable the Chromium browser";
          work.enable = cascade (config.fireproof.desktop.chromium.enable && config.fireproof.work.enable) "Enable a separate chromium-work instance (own profile, runs alongside the personal one)";
        };
        bambu-studio.enable = lib.mkEnableOption "Bambu Studio 3D printing slicer";
        google-chrome.enable = lib.mkEnableOption "Google Chrome";
        jellyfin-media-player.enable = lib.mkEnableOption "Jellyfin Media Player desktop client";
        ivpn.enable = lib.mkEnableOption "IVPN client (daemon + CLI + desktop UI)";
        mullvad.enable = lib.mkEnableOption "Mullvad VPN client (daemon + CLI + desktop UI)";
        snapcast.enable = lib.mkEnableOption "Snapcast audio streaming server";
        oxcbMedia.enable = lib.mkEnableOption "0xCB-media host daemon (bridges MPRIS + PipeWire to the 0xCB-1337 macropad over USB CDC ACM)";
        lan-mouse.enable = lib.mkEnableOption "Lan Mouse — LAN keyboard/mouse sharing (edge-crossing KVM). On niri it uses the layer-shell capture backend (no input-capture portal needed)";
      };

      claude-code.work.enable =
        lib.mkEnableOption "claude-work wrapper sharing the personal claude-code config via ~/.claude-work";

      # Registry: leaves register skills next to the feature they document (e.g.
      # git.nix registers gh-stack from the extension's own source — third-party
      # skills are referenced upstream, never vendored); the agent leaves
      # (claude-code, copilot, pi) consume the merged set.
      agents.skills = lib.mkOption {
        type = lib.types.attrsOf lib.types.path;
        default = {};
        description = "Agent skill directories by skill name, installed for every coding agent.";
      };

      # GUI apps all gate on desktop.enable (plus dev/work where relevant) — no
      # per-app toggles. A leaf adds a Homebrew cask in its flake.modules.darwin
      # half and installs the nixpkgs build in its homeManager half; Mac-only apps
      # (karabiner, bitwarden, handy, …) ship a darwin half only. Home-manager
      # halves that can't run on macOS gate additionally on pkgs.stdenv.isLinux,
      # so desktop.enable on the darwin macbook mirrors the Linux desktop minus
      # the Linux-only DE (niri, dms, gtk, …).

      dev = {
        enable = lib.mkEnableOption "development tools and applications";
        intellij.enable = cascade config.fireproof.dev.enable "Enable IntelliJ-based IDEs";
        clickhouse.enable = cascade config.fireproof.dev.enable "Enable Clickhouse";
        k8s.enable = cascade (config.fireproof.dev.enable && config.fireproof.work.enable) "Enable kubectl and the AO kube configs";
        mcp = {
          enable = cascade config.fireproof.dev.enable "Enable MCP servers";
          homelab.enable = cascade config.fireproof.dev.mcp.enable "Enable the homelab Grafana MCP server and its token secret";
        };
        pi.enable = cascade config.fireproof.dev.enable "Enable the pi coding agent with the lazypi extension roster";
        llm = {
          enable = lib.mkEnableOption ''
            local LLM serving (llama-swap + CUDA llama.cpp) and its pi provider.
            Off by default rather than following dev.enable: it needs a ≥12GB
            NVIDIA GPU, which macbook and dev-ao don't have
          '';
          vramGiB = lib.mkOption {
            type = lib.types.enum [12 16];
            default = 16;
            description = ''
              VRAM tier of the serving GPU; picks the quant/context set in
              modules/programs/_llm-models.nix, each tuned to fit that card.
            '';
          };
        };
      };

      neovim.full.enable = cascade config.fireproof.dev.enable ''
        Layer the heavy neovim language support (pyrefly/TS/web LSPs + their
        tree-sitter grammars) on top of the always-on lean baseline.
        Defaults to dev.enable; override off to keep the editor lean.
      '';

      networkd.enable = lib.mkEnableOption "systemd-networkd wired networking";
      wsl.enable = lib.mkEnableOption "WSL configuration";

      tailscale = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Run tailscaled and join the personal tailnet.";
        };
        autoLogin = cascade config.fireproof.tailscale.enable ''
          Enrol declaratively with the OAuth auth key. Off means `tailscale up`
          by hand — for machines that shouldn't silently join the tailnet.
        '';
      };

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
        physical = cascade (!config.fireproof.wsl.enable) "Whether this is a physical machine (not WSL/VM). Enables baseline hardware hygiene: SMART monitoring, thermald, zram, btrfs scrub, firmware/fwupd and removable-media automount.";
        zram = cascade config.fireproof.hardware.physical "Enable compressed RAM swap (zram) for memory-pressure headroom without writing to disk.";
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
        battery = cascade config.fireproof.hardware.laptop "Enable battery support (UPower, battery widget, etc.)";
        wifi = cascade config.fireproof.hardware.laptop "Enable WiFi support (NetworkManager, wireless tools, etc.)";
        dimmableBacklight = cascade config.fireproof.hardware.laptop "Enable dimmable backlight support (brightnessctl, backlight widget, etc.)";
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
            vrr = lib.mkEnableOption "on-demand VRR in niri: active only while a window that opts in is on this output";
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
