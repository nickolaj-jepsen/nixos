{
  flake.modules.nixos.journald = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf config.fireproof.hardware.physical {
      # mkDefault so a host wanting more history can raise SystemMaxUse with a plain assignment.
      services.journald.extraConfig = lib.mkDefault ''
        SystemMaxUse=2G
        SystemMaxFileSize=128M
        MaxRetentionSec=2week
      '';
    };
  };
}
