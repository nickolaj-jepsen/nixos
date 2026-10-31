{
  flake.modules.nixos.greetd = {
    config,
    lib,
    pkgs,
    ...
  }: let
    autologin = pkgs.writers.writePython3Bin "greetd-autologin" {} (builtins.readFile ./autologin.py);
    always = config.fireproof.desktop.autologin.enable;
  in {
    config = lib.mkIf config.fireproof.desktop.enable {
      services.greetd = {
        enable = true;
        settings = {
          # Skips tuigreet only when PAM signs in silently with the typed LUKS passphrase; a
          # TPM unlock caches none, so those hosts (and mismatched passwords) still get a prompt.
          # With autologin PAM always signs in silently, so tuigreet only catches IPC failures.
          default_session.command = lib.escapeShellArgs [
            (lib.getExe autologin)
            config.fireproof.username
            (lib.getExe' config.programs.niri.package "niri-session")
            "--"
            (lib.getExe pkgs.tuigreet)
            "--user-menu"
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
