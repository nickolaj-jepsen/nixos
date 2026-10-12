# Refuse to activate one host's closure on another (`just switch homelab me@minilab`).
# Fails instead of prompting: --target-host has no TTY. `boot` skips it, which is
# the way through for an install or a rename.
{
  flake.modules.nixos.switch-guards = {
    config,
    lib,
    ...
  }: let
    host = config.networking.hostName;
  in {
    system.preSwitchChecks.hostname = lib.mkIf (host != "") ''
      case "''${2-}" in boot | dry-activate) exit 0 ;; esac
      actual=$(< /proc/sys/kernel/hostname)
      if [ "$actual" != ${lib.escapeShellArg host} ]; then
        echo "This configuration is for ${host}, but this machine is $actual; refusing to switch."
        echo "Renaming a host? Use boot (just boot) and reboot instead."
        exit 1
      fi
    '';
  };
}
