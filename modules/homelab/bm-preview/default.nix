# Draft preview for bmtomrermontage.dk: a container that runs `astro build`
# against the CMS's draft endpoint whenever Payload POSTs /rebuild (debounced
# CMS-side, a few seconds after every save) and serves the result. Editors see
# drafts here; the production site on Cloudflare never talks to this host.
#
# This module also grafts the preview wiring onto the bm-cms container (shared
# docker network, hook URL, shared secret) so everything preview lives here.
#
# Manual steps before `just switch`:
#   - `agenix edit secrets/hosts/homelab/bm-preview-env.age` with
#     PREVIEW_SECRET=<long random string> (shared by both containers).
#   - `agenix edit secrets/hosts/homelab/bm-preview-htpasswd.age` with an
#     htpasswd line for the customer (nix run nixpkgs#apacheHttpd — htpasswd -nB).
#   - A DNS record for preview.bmtomrermontage.dk pointing at this host.
#   - Pin _image.nix from the bm-website CI `preview-image` job summary.
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
      # KEY=value: PREVIEW_SECRET only. Guards /api/site-content-draft on the
      # CMS and /rebuild on this container, so both containers load it.
      age.secrets.bm-preview-env.rekeyFile = ../../../secrets/hosts/homelab/bm-preview-env.age;
      age.secrets.bm-preview-htpasswd = {
        rekeyFile = ../../../secrets/hosts/homelab/bm-preview-htpasswd.age;
        owner = "nginx";
      };

      # A named network so the CMS can reach `bm-preview` (and the preview
      # build `bm-cms`) by container name; the default bridge has no DNS.
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

      # The preview half of bm-cms's config: draft saves POST the rebuild hook
      # over the shared network, and the admin's Preview button opens ${domain}.
      virtualisation.oci-containers.containers.bm-cms = {
        environment = {
          PREVIEW_DEPLOY_HOOK_URL = "http://bm-preview:8080/rebuild";
          PREVIEW_URL = "https://${domain}";
        };
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

      # Basic auth because this serves unpublished content; /rebuild is only
      # for the CMS over the docker network, so the vhost never exposes it
      # (the server checks a bearer token besides).
      services.nginx.virtualHosts."${domain}" =
        fpLib.mkVirtualHost {
          inherit port;
          extraLocations."/rebuild" = {return = "404";};
        }
        // {
          basicAuthFile = config.age.secrets.bm-preview-htpasswd.path;
          extraConfig = ''
            add_header X-Robots-Tag "noindex, nofollow" always;
          '';
        };
    };
  };
}
