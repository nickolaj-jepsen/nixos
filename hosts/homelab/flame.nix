_: let
  dataDir = "/var/lib/flame";
  domain = "flame.nickolaj.com";
in {
  services.restic.backups.homelab.paths = [dataDir];

  services.nginx.virtualHosts."${domain}" = {
    enableACME = true;
    forceSSL = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:5005";
    };
  };

  virtualisation.oci-containers = {
    containers = {
      flame = {
        autoStart = true;
        image = "pawelmalak/flame:2.3.1";
        volumes = [
          "${dataDir}:/app/data"
        ];
        ports = [
          "127.0.0.1:5005:5005"
        ];
      };
    };
  };
}
