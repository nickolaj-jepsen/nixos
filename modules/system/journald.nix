{
  config,
  lib,
  ...
}: {
  # Bound the journal's on-disk growth. mkDefault so individual hosts (e.g.
  # the homelab server, which wants more history) can raise SystemMaxUse with
  # a plain assignment.
  config = lib.mkIf config.fireproof.hardware.physical {
    services.journald.extraConfig = lib.mkDefault ''
      SystemMaxUse=2G
      SystemMaxFileSize=128M
      MaxRetentionSec=2week
    '';
  };
}
