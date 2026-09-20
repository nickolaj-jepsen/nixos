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
  in {
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
          path = ./kctx.bash;
          runtimeInputs = with pkgs; [
            kubectl
            fzf
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
        (makeScript {
          path = ./wt.bash;
          runtimeInputs = with pkgs; [
            git
            fzf
            diffnav # for the diff verb
            util-linux # for column
            gawk
            gnused
            gnugrep
            findutils
            coreutils
          ];
        })
      ]
      # systemd-only scripts (the systemd package isn't built on darwin).
      ++ lib.optionals pkgs.stdenv.isLinux [
        (makeScript {
          path = ./reboot-windows.bash;
          runtimeInputs = with pkgs; [
            jq
            systemd # for bootctl and systemctl
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
      ];
  };
}
