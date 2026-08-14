# Manual steps before `just switch`:
#   - bm-preview-env.age: PREVIEW_SECRET=<long random string>
#   - bm-preview-htpasswd.age: htpasswd -nB line for the customer
#   - DNS record: preview.bmtomrermontage.dk -> this host
#   - Pin _image.nix from the bm-website CI `preview-image` job summary
{
  flake.modules.nixos.bm-preview = {
    config,
    lib,
    pkgs,
    fpLib,
    ...
  }: let
    domain = "preview.bmtomrermontage.dk";
    port = 4321;
    network = "bm";
  in {
    config = lib.mkIf config.fireproof.homelab.enable {
      age.secrets.bm-preview-env.rekeyFile = ../../../secrets/hosts/homelab/bm-preview-env.age;
      age.secrets.bm-preview-htpasswd = {
        rekeyFile = ../../../secrets/hosts/homelab/bm-preview-htpasswd.age;
        owner = "nginx";
      };

      # Named network: default docker bridge has no DNS for container names.
      systemd.services.docker-network-bm = {
        after = ["docker.service"];
        requires = ["docker.service"];
        wantedBy = ["multi-user.target"];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          ${pkgs.docker}/bin/docker network inspect ${network} >/dev/null 2>&1 \
            || ${pkgs.docker}/bin/docker network create ${network}
        '';
      };

      virtualisation.oci-containers.containers.bm-preview = {
        image = import ./_image.nix;
        login = {
          registry = "ghcr.io";
          username = "nickolaj-jepsen";
          passwordFile = config.age.secrets.ghcr-pull-token.path;
        };
        environment.CMS_URL = "http://bm-cms:3000";
        environmentFiles = [config.age.secrets.bm-preview-env.path];
        ports = ["127.0.0.1:${toString port}:8080"];
        extraOptions = ["--network=${network}"];
      };

      virtualisation.oci-containers.containers.bm-cms = {
        environment.PREVIEW_URL = "https://${domain}";
        environmentFiles = [config.age.secrets.bm-preview-env.path];
        extraOptions = ["--network=${network}"];
      };

      systemd.services.docker-bm-preview = {
        after = ["docker-network-bm.service"];
        requires = ["docker-network-bm.service"];
        serviceConfig = {
          Restart = lib.mkForce "always";
          RestartSec = "15s";
        };
      };
      systemd.services.docker-bm-cms = {
        after = ["docker-network-bm.service"];
        requires = ["docker-network-bm.service"];
      };

      services.nginx.virtualHosts."${domain}" =
        fpLib.mkVirtualHost {inherit port;}
        // {
          basicAuthFile = config.age.secrets.bm-preview-htpasswd.path;
          extraConfig = ''
            add_header X-Robots-Tag "noindex, nofollow" always;
          '';
        };
    };
  };
}
