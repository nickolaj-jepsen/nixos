{
  flake.modules.homeManager.scripts = {
    pkgs,
    lib,
    config,
    ...
  }: let
    makeScript = {
      path,
      name ? lib.removeSuffix ".bash" (builtins.baseNameOf path),
      runtimeInputs ? [],
    }:
      pkgs.writeShellApplication {
        inherit name runtimeInputs;
        text = builtins.readFile path;
      };
    agent-note-open = makeScript {
      path = ./agent-note-open.bash;
      runtimeInputs = [pkgs.coreutils] ++ lib.optional config.fireproof.dev.enable editor-open;
    };
    # The editor the desktop hands a path to, in its own argv: see editor-open.bash. It reads
    # PATH, so a host with no GUI editor opens nvim rather than pulling a GUI in.
    editor-open = pkgs.writeShellApplication {
      name = "editor-open";
      text =
        builtins.replaceStrings ["@editor@" "@bridgePort@"] [config.fireproof.desktop.editor (toString bridgePort)]
        (builtins.readFile ./editor-open.bash);
    };
    # Hands one request from the ssh reverse forward to the editor: see editor-open-bridge.bash.
    editor-open-bridge = pkgs.writeShellApplication {
      name = "editor-open-bridge";
      runtimeInputs = [pkgs.coreutils editor-open];
      text =
        builtins.replaceStrings ["@bridgeHosts@"] [(lib.concatStringsSep " " bridgeHosts)]
        (builtins.readFile ./editor-open-bridge.bash);
    };
    # The Ghostty xdg-open shim is a Linux desktop's, even though editor-open is any dev host's.
    desktopShim = config.fireproof.desktop.enable && config.fireproof.dev.enable && pkgs.stdenv.isLinux;
    # The editor answering another host's ssh connection is a GUI host's job too.
    editorBridge = config.fireproof.desktop.enable && pkgs.stdenv.isLinux;
    # One request in, one editor out; a request that says nothing dies after a few seconds.
    bridgePort = 47110;
    # The hosts whose ssh sessions may ask this machine's editor to open a path, by the name
    # this ssh config knows them by: the ones running this config, gated like their blocks. A
    # name outside this list is refused by editor-open-bridge, since the editor would ssh to
    # whatever it was told with this machine's keys.
    bridgeHosts =
      lib.optionals config.fireproof.trusted ["homelab" "minilab" "desktop" "macbook"]
      ++ lib.optionals config.fireproof.work.enable ["dev.ao"];
    # Nothing forwards to a host that runs the socket itself: this machine's editor is right
    # there, and sshd on the far end could not bind the port under it.
    forwardHosts = lib.remove config.fireproof.hostname bridgeHosts;
  in {
    # The bridge on the GUI end: sshd on the remote forwards one connection here, and this
    # socket hands it to editor-open-bridge. The forward itself is declared below, per host.
    systemd.user.sockets = lib.mkIf editorBridge {
      editor-open-bridge = {
        Unit.Description = "editor-open requests forwarded from another host's ssh connection";
        Socket = {
          ListenStream = "127.0.0.1:${toString bridgePort}";
          Accept = true;
        };
        Install.WantedBy = ["sockets.target"];
      };
    };
    systemd.user.services = lib.mkIf editorBridge {
      "editor-open-bridge@" = {
        Unit.Description = "Open the path an ssh session on another host asked for";
        Service = {
          ExecStart = lib.getExe editor-open-bridge;
          StandardInput = "socket";
          # `ok` is the answer editor-open reads; the editor's own chatter stays in the journal.
          StandardOutput = "socket";
          StandardError = "journal";
        };
      };
    };
    # The remote end needs SetEnv to reach it (sshd's AcceptEnv in modules/system/ssh.nix) and
    # the forward to be there before it starts.
    programs.ssh.settings = lib.mkIf editorBridge (
      lib.genAttrs forwardHosts (host: {
        SetEnv = {EDITOR_OPEN_HOST = host;};
        RemoteForward = ["127.0.0.1:${toString bridgePort} 127.0.0.1:${toString bridgePort}"];
      })
    );

    age.secrets = lib.optionalAttrs (config.fireproof.scripts.tunnel-home.enable && pkgs.stdenv.isLinux) {
      tunnel-home = {
        rekeyFile = ../../secrets/tunnel-home.age;
        mode = "0400";
      };
    };

    home.packages =
      [
        (makeScript {
          path = ./port-kill.bash;
          runtimeInputs = with pkgs; [
            lsof
            procps
            coreutils
          ];
        })
        (makeScript {
          path = ./ssh-select.bash;
          runtimeInputs = with pkgs; [
            fzf
            openssh
            gawk
            gnused
            coreutils
          ];
        })
        (makeScript {
          path = ./ghpr.bash;
          runtimeInputs = with pkgs; [
            unstable.gh # same build as programs.gh, so only one lands in the closure
            fzf
            util-linux # for column
            gawk
            less
            coreutils
          ];
        })
        pkgs.wt
      ]
      ++ lib.optional config.fireproof.dev.enable agent-note-open
      # Every dev host: a remote shell without a GUI editor opens nvim.
      ++ lib.optional config.fireproof.dev.enable editor-open
      # systemd-only scripts (the systemd package isn't built on darwin).
      ++ lib.optionals pkgs.stdenv.isLinux [
        (makeScript {
          path = ./reboot-windows.bash;
          runtimeInputs = with pkgs; [
            efibootmgr
            gnused
            coreutils
            systemd # for systemctl
          ];
        })
        (makeScript {
          path = ./journalctl-select.bash;
          runtimeInputs = with pkgs; [
            fzf
            systemd
            gnused
            coreutils
          ];
        })
      ]
      # The secret body gets no build-time shellcheck — test before committing.
      ++ lib.optionals (config.fireproof.scripts.tunnel-home.enable && pkgs.stdenv.isLinux) [
        (pkgs.writeShellApplication {
          name = "tunnel-home";
          runtimeInputs = with pkgs; [
            sshuttle
            openssh
            nftables
            iptables
            tailscale
            jq
            gawk
            coreutils
          ];
          text = ''
            exec ${lib.getExe pkgs.bash} "${config.age.secrets.tunnel-home.path}" "$@"
          '';
        })
      ]
      # Wayland screenshot tooling — Linux desktop only.
      ++ lib.optionals (config.fireproof.desktop.enable && pkgs.stdenv.isLinux) [
        (makeScript {
          path = ./screenshot.bash;
          runtimeInputs = with pkgs; [
            slurp
            grim
            satty
            wl-clipboard
          ];
        })
        (makeScript {
          path = ./window-kill.bash;
          runtimeInputs = with pkgs; [
            niri-unstable # match the running compositor's IPC
            jq
            procps
          ];
        })
        (makeScript {
          path = ./ghostty-here.bash;
          runtimeInputs = with pkgs; [
            niri-unstable # match the running compositor's IPC
            jq
            procps
            gawk
          ];
        })
      ]
      # Shadows the system xdg-open (per-user profile precedes it on PATH) so Ghostty link clicks land in the editor.
      ++ lib.optionals desktopShim [
        (lib.hiPrio (pkgs.writeShellApplication {
          name = "xdg-open";
          runtimeInputs = with pkgs; [
            procps
            gawk
            coreutils
            file
            git
            libnotify
          ];
          text =
            builtins.replaceStrings ["@xdgOpen@" "@agentNoteOpen@" "@editorOpen@"] [
              "${pkgs.xdg-utils}/bin/xdg-open"
              (lib.getExe agent-note-open)
              (lib.getExe editor-open)
            ]
            (builtins.readFile ./ghostty-xdg-open.bash);
        }))
      ];
  };
}
