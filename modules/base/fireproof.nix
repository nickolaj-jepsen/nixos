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

      # Personal secrets and identity default off here; work-owned ones still ship.
      sharedHost.enable = lib.mkEnableOption "a host other people can be root on, so personal secrets stay off it";

      work = {
        enable = lib.mkEnableOption "work-related applications and tools";
        sshKey.enable = cascade (config.fireproof.work.enable && !config.fireproof.sharedHost.enable) "Decrypt the shared AO SSH key and load it into ssh-agent";
      };

      # Enabling a host needs `just secret-rekey` — the body is an agenix secret.
      scripts.tunnel-home.enable = lib.mkEnableOption "tunnel-home, an sshuttle wrapper for reaching a remote network over SSH";

      desktop = {
        enable = lib.mkEnableOption "desktop environment with niri, greetd, and all desktop features";
        chromium = {
          enable = cascade config.fireproof.desktop.enable "Enable the Chromium browser";
          work.enable = cascade (config.fireproof.desktop.chromium.enable && config.fireproof.work.enable) "Enable a separate chromium-work instance (own profile, runs alongside the personal one)";
        };
        bambu-studio.enable = lib.mkEnableOption "Bambu Studio 3D printing slicer";
        jellyfin-media-player.enable = lib.mkEnableOption "Jellyfin Media Player desktop client";
        ivpn.enable = lib.mkEnableOption "IVPN client (daemon + CLI + desktop UI)";
        mullvad.enable = lib.mkEnableOption "Mullvad VPN client (daemon + CLI + desktop UI)";
        snapcast.enable = lib.mkEnableOption "Snapcast audio streaming server";
        oxcbMedia.enable = lib.mkEnableOption "0xCB-media host daemon (bridges MPRIS + PipeWire to the 0xCB-1337 macropad over USB CDC ACM)";
        lan-mouse.enable = lib.mkEnableOption "Lan Mouse — LAN keyboard/mouse sharing (edge-crossing KVM). On niri it uses the layer-shell capture backend (no input-capture portal needed)";
      };

      claude-code = {
        work.enable =
          lib.mkEnableOption "claude-work wrapper sharing the personal claude-code config via ~/.claude-work";
        workMcpServers = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = {};
          description = ''
            MCP servers only the claude-work wrapper loads. Work-owned services
            stay out of programs.mcp.servers, which every agent (pi,
            copilot, vscode and the personal claude) reads.
          '';
        };
      };

      # Registry: leaves register skills next to the feature they document; third-party
      # skills are referenced from their upstream source, never vendored.
      agents.skills = lib.mkOption {
        type = lib.types.attrsOf lib.types.path;
        default = {};
        description = "Agent skill directories by skill name, installed for every coding agent.";
      };

      # Same registry pattern for language servers; each agent leaf maps them to its own schema.
      agents.lspServers = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule {
          options = {
            command = lib.mkOption {
              type = lib.types.str;
              description = "Store path of the server binary; agents spawn it with whatever PATH the terminal had.";
            };
            args = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [];
              description = "Arguments passed to the server.";
            };
            extensionToLanguage = lib.mkOption {
              type = lib.types.attrsOf lib.types.str;
              description = "LSP language id by file extension (with the leading dot).";
            };
          };
        });
        default = {};
        description = "Language servers by name, configured for every coding agent that speaks LSP.";
      };

      # docs/janitor.md: temp roots, finished jobs, merged
      # branches, finished worktrees and the rebuildable build dirs nobody opened.
      janitor.enable = cascade config.fireproof.dev.enable "Reclaim what agents and dev tools leave behind";

      # Cross-platform GUI app packaging: docs/hosts.md "Cross-platform apps".

      dev = {
        enable = lib.mkEnableOption "development tools and applications";
        intellij.enable = cascade config.fireproof.dev.enable "Enable IntelliJ-based IDEs";
        clickhouse.enable = cascade config.fireproof.dev.enable "Enable Clickhouse";
        k8s.enable = cascade (config.fireproof.dev.enable && config.fireproof.work.enable) "Enable kubectl and the AO kube configs";
        scaleway.enable = cascade (config.fireproof.dev.enable && config.fireproof.work.enable) "Enable the Scaleway CLI (scw) and its b2c-devenv/b2c-production profiles";
        mcp = {
          enable = cascade config.fireproof.dev.enable "Enable MCP servers";
          homelab.enable = cascade (config.fireproof.dev.mcp.enable && !config.fireproof.sharedHost.enable) "Enable the homelab Grafana MCP server and its token secret";
        };
        pi.enable = cascade (config.fireproof.dev.enable && !config.fireproof.sharedHost.enable) "Enable the pi coding agent with the lazypi extension roster";
        copilot.enable = cascade config.fireproof.dev.enable "Enable the GitHub Copilot CLI";
        ai-usage.enable = cascade config.fireproof.dev.enable "Enable ai-usage, the agent subscription quota CLI (and its DMS bar widget on desktops)";
        agent-hub.enable = cascade (config.fireproof.dev.enable && config.fireproof.desktop.enable) "Enable agent-hub, the DMS bar hub for live coding-agent sessions and their permission asks";
        llm = {
          enable = lib.mkEnableOption ''
            local LLM serving (llama-swap + CUDA llama.cpp).
            Off by default rather than following dev.enable: it needs a ≥12GB
            NVIDIA GPU
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
        plex.enable = lib.mkEnableOption "Plex Media Server. Off by default: kept only until everyone has moved to Jellyfin";
        dashboard.monitors = lib.mkOption {
          type = lib.types.attrsOf (lib.types.submodule {
            options = {
              title = lib.mkOption {type = lib.types.str;};
              url = lib.mkOption {
                type = lib.types.str;
                description = "Link opened from the dashboard; also probed unless checkUrl is set.";
              };
              icon = lib.mkOption {
                type = lib.types.str;
                example = "sh:jellyfin";
              };
              group = lib.mkOption {
                type = lib.types.enum ["home" "media" "downloads" "infra"];
                description = "Dashboard section; the renderer orders sections and sorts by title within each.";
              };
              # SSO-gated sites need a loopback check-url; the public URL only reaches the Zitadel login.
              checkUrl = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "URL Glance probes instead of url.";
              };
              altStatusCodes = lib.mkOption {
                type = lib.types.listOf lib.types.int;
                default = [];
                description = "Extra HTTP status codes that count as up.";
              };
            };
          });
          default = {};
          description = "Glance home-page monitor entries, set by each service leaf.";
        };
      };

      hardware = {
        physical = cascade (!config.fireproof.wsl.enable) "Whether this is a physical machine (not WSL/VM). Gates baseline hardware hygiene for physical machines.";
        zram = cascade config.fireproof.hardware.physical "Enable compressed RAM swap (zram) for memory-pressure headroom without writing to disk.";
        nvidia.enable = lib.mkEnableOption "NVIDIA GPU support (open kernel module + VA-API video offload)";
        laptop = lib.mkEnableOption "laptop-specific configurations and tools";
        battery = cascade config.fireproof.hardware.laptop "Enable battery support (UPower, power-profiles-daemon, DMS battery widgets).";
        wifi = cascade config.fireproof.hardware.laptop "Show the DMS Wi-Fi and VPN tiles. Both need NetworkManager, which the host card enables itself.";
        dimmableBacklight = cascade config.fireproof.hardware.laptop "Show the DMS brightness slider (built-in dimmable backlight).";
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
