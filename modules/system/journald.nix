{
  flake.modules.nixos.journald = {lib, ...}: {
    # Ungated: the cap is about disk, and the WSL VHD never shrinks on its own.
    # mkDefault so a host wanting more history can raise SystemMaxUse with a plain assignment.
    services.journald.extraConfig = lib.mkDefault ''
      SystemMaxUse=2G
      SystemMaxFileSize=128M
      MaxRetentionSec=2week
    '';
  };
}
