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
            gh
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
      ];
  };
}
