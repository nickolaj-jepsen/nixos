{
  flake.modules.nixos.greetd = {
    config,
    lib,
    pkgs,
    ...
  }: let
    autologin = pkgs.writers.writePython3Bin "greetd-autologin" {} (builtins.readFile ./autologin.py);
  in {
    config = lib.mkIf config.fireproof.desktop.enable {
      services.greetd = {
        enable = true;
        settings = {
          # Skips tuigreet only when PAM signs in silently with the typed LUKS passphrase; a
          # TPM unlock caches none, so those hosts (and mismatched passwords) still get a prompt.
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
        # unix-early otherwise always prompts, ignoring the loaded authtok.
        unix-early.settings.try_first_pass = true;
      };

      # Activate HM at login instead of a boot unit ordered before systemd-user-sessions,
      # which held the greeter ~5 s re-linking an unchanged generation. Switches still reactivate.
      home-manager.startAsUserService = true;
    };
  };
}
