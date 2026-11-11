{inputs, ...}: {
  flake.modules.nixos.greetd = {
    config,
    lib,
    pkgs,
    ...
  }: let
    autologin = pkgs.writers.writePython3Bin "greetd-autologin" {} (builtins.readFile ./autologin.py);
    always = config.fireproof.desktop.autologin.enable;
    c = config.fireproof.theme.colors;
    user = config.users.users.${config.fireproof.username};
    dmsGreeter = config.programs.dms-greeter;

    # The greeter's own niri: the session's outputs and background, so neither the greeter nor
    # the handover to the session's niri changes a mode or flashes another colour. Not the
    # session config itself: its binds would open a terminal as the greeter user.
    outputKdl = m:
      if !m.enable
      then ''
        output "${m.name}" {
            off
        }
      ''
      else ''
        output "${m.name}" {
            ${lib.optionalString (m.resolution.width != null && m.refreshRateNiri != null)
          ''mode "${toString m.resolution.width}x${toString m.resolution.height}@${toString m.refreshRateNiri}"''}
            position x=${toString m.position.x} y=${toString m.position.y}
            scale ${toString m.scale}
            transform "${
          if m.transform == null || m.transform == 0
          then "normal"
          else toString (m.transform * 90)
        }"
        }
      '';
    greeterNiriConfig =
      pkgs.runCommand "dms-greeter-niri.kdl" {
        config = ''
          hotkey-overlay {
              skip-at-startup
          }
          environment {
              DMS_RUN_GREETER "1"
          }
          input {
              keyboard {
                  xkb {
                      layout "eu"
                  }
                  numlock
              }
          }
          gestures {
              hot-corners {
                  off
              }
          }
          cursor {
              xcursor-theme "Adwaita"
              xcursor-size 24
          }
          layout {
              background-color "#${c.bg}"
          }
          ${lib.concatMapStringsSep "\n" outputKdl (lib.filter (m: m.name != null) config.fireproof.monitors)}
        '';
        passAsFile = ["config"];
        nativeBuildInputs = [config.programs.niri.package];
      } ''
        niri validate -c $configPath
        cp $configPath $out
      '';

    # Temporary, while niri and Hyprland run side by side: the greeter always shows, since its
    # session picker is how one is chosen. Dropping fireproof.desktop.hyprland restores the
    # silent sign-in.
    pickSession = config.fireproof.desktop.hyprland.enable;

    # What programs.dms-greeter would set as default_session.command, which autologin.py
    # runs only when PAM can't sign in silently.
    greeter = pkgs.writeShellScript "dms-greeter-session" ''
      export PATH=$PATH:${lib.makeBinPath [dmsGreeter.compositor.package pkgs.glib]}
      exec ${lib.getExe dmsGreeter.package} --cache-dir /var/lib/dms-greeter --command niri \
        -C ${greeterNiriConfig}
    '';
  in {
    imports = [inputs.dux-greeter.nixosModules.default];

    config = lib.mkIf config.fireproof.desktop.enable {
      # Theme, wallpaper and lock-screen layout are copied from the user's DMS config on start.
      programs.dms-greeter = {
        enable = true;
        compositor = {
          name = "niri";
          package = config.programs.niri.package;
        };
        configHome = user.home;
      };

      services.greetd = {
        enable = true;
        settings = {
          # Skips the greeter only when PAM signs in silently with the typed LUKS passphrase; a
          # TPM unlock caches none, so those hosts (and mismatched passwords) still get a prompt.
          # With autologin PAM always signs in silently, so the greeter only catches IPC failures.
          # programs.dms-greeter's own autologin would skip PAM auth and leave the keyring locked.
          default_session.command =
            if pickSession
            then "${greeter}"
            else
              lib.escapeShellArgs [
                (lib.getExe autologin)
                config.fireproof.username
                (lib.getExe' config.programs.niri.package "niri-session")
                "--"
                greeter
              ];
        };
      };

      security.pam.services.greetd.rules.auth = {
        # systemd-cryptsetup keeps a typed passphrase in root's keyring for 2.5 min; use it as
        # the login password, which also unlocks gnome-keyring. No-op when nothing is cached.
        systemd_loadkey = {
          order = config.security.pam.services.greetd.rules.auth.unix-early.order - 10;
          control = "optional";
          modulePath = "${config.systemd.package}/lib/security/pam_systemd_loadkey.so";
        };
        # unix-early otherwise always prompts, ignoring the loaded authtok; with autologin it
        # must not prompt at all.
        unix-early.settings = {
          try_first_pass = !always;
          use_first_pass = always;
        };
        # After gnome_keyring has stashed any cached passphrase, so the keyring still unlocks.
        autologin = lib.mkIf always {
          order = config.security.pam.services.greetd.rules.auth.gnome_keyring.order + 10;
          control = "sufficient";
          modulePath = "${config.security.pam.package}/lib/security/pam_succeed_if.so";
          args = ["quiet" "user" "=" config.fireproof.username];
        };
      };

      # Activate HM at login instead of a boot unit ordered before systemd-user-sessions,
      # which held the greeter ~5 s re-linking an unchanged generation. Switches still reactivate.
      home-manager.startAsUserService = true;
    };
  };
}
