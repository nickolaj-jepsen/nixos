{fpLib, ...}: {
  flake.modules.nixos.immich = {
    config,
    lib,
    pkgs,
    ...
  }: let
    domain = "immich.${config.fireproof.homelab.domain}";
    port = 2283;
  in {
    config = lib.mkIf config.fireproof.homelab.enable {
      services.restic.backups.homelab.paths = ["/var/lib/immich"];

      services.nginx.virtualHosts."${domain}" = fpLib.mkVirtualHost {
        inherit port;
        websockets = true;
        extraConfig = ''
          client_max_body_size 50000M;
          proxy_read_timeout 600s;
          send_timeout 600s;
        '';
      };

      users.users.immich.extraGroups = ["video" "render"];

      services.immich = {
        enable = true;
        package = pkgs.unstable.immich;
        host = "127.0.0.1";
        inherit port;
        machine-learning.enable = true;
        accelerationDevices = [
          "/dev/nvidia0"
          "/dev/nvidiactl"
          "/dev/nvidia-uvm"
          "/dev/nvidia-uvm-tools"
          "/dev/nvidia-modeset"
        ];
      };

      systemd.services.immich-server.environment = {
        LIBVA_DRIVER_NAME = "nvidia";
        NVD_BACKEND = "direct";
      };
    };
  };
}
