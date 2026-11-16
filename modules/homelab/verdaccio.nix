# A private npm registry for packages not ready for npmjs.
{fpLib, ...}: {
  flake.modules.nixos.verdaccio = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.fireproof.homelab;
    domain = "npm.${cfg.domain}";
    port = 4873;
    stateDir = "/var/lib/verdaccio";
    # The image's verdaccio user.
    uid = 10001;
    gid = 65533;
    maxBody = "200mb";

    # Literal YAML: Verdaccio takes the first matching `packages` rule, and a Nix attrset would sort `**` first.
    settings = pkgs.writeText "verdaccio.yaml" ''
      storage: /verdaccio/storage/data
      auth:
        htpasswd:
          file: /verdaccio/storage/htpasswd
          # The first `npm adduser` registers; this then closes sign-up.
          max_users: 1
      uplinks:
        npmjs:
          url: https://registry.npmjs.org/
      packages:
        # Never proxied, so npmjs can't serve a name in this scope.
        '@sjusk/*':
          access: $all
          publish: $authenticated
          unpublish: $authenticated
        # sjusk's builds of pi and Gondolin beside npmjs's releases, readable by envs and VMs that hold no token.
        '@earendil-works/*':
          access: $all
          publish: $authenticated
          unpublish: $authenticated
          proxy: npmjs
        # Signed in only, so the vhost isn't an open npmjs proxy.
        '**':
          access: $authenticated
          publish: $authenticated
          unpublish: $authenticated
          proxy: npmjs
      max_body_size: ${maxBody}
      web:
        title: npm
      log:
        type: stdout
        format: pretty
        level: http
    '';
  in {
    config = lib.mkIf config.fireproof.homelab.enable {
      virtualisation.docker.enableOnBoot = true;

      systemd.tmpfiles.rules = ["d ${stateDir} 0750 ${toString uid} ${toString gid} -"];

      virtualisation.oci-containers.containers.verdaccio = {
        image = "verdaccio/verdaccio:6.11.2";
        environment.VERDACCIO_PUBLIC_URL = "https://${domain}";
        volumes = [
          "${settings}:/verdaccio/conf/config.yaml:ro"
          "${stateDir}:/verdaccio/storage"
        ];
        ports = ["127.0.0.1:${toString port}:4873"];
      };

      services.nginx.virtualHosts."${domain}" = fpLib.mkVirtualHost {
        inherit port;
        extraConfig = "client_max_body_size ${lib.removeSuffix "mb" maxBody}M;";
      };
      # No oauth2-proxy gate: npm and pnpm can't do the OIDC browser flow, so publishing rests on Verdaccio's own login.

      fireproof.homelab.dashboard.monitors.verdaccio = {
        title = "Verdaccio";
        url = "https://${domain}";
        checkUrl = "http://127.0.0.1:${toString port}/-/ping";
        icon = "sh:verdaccio";
        group = "infra";
      };

      services.restic.backups.homelab.paths = [stateDir];
    };
  };
}
