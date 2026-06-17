{
  flake.aspectTags.attic = ["homelab"];
  flake.modules.nixos.attic = {
    config,
    fpLib,
    ...
  }: let
    cfg = config.fireproof.homelab;
    domain = "attic.${cfg.domain}";
    port = 8090;
  in {
    config = {
      age.secrets.atticd-env = {
        rekeyFile = ../../secrets/hosts/homelab/atticd-env.age;
        # atticd uses systemd DynamicUser, so the "atticd" user does not exist
        # at agenix activation time. systemd reads EnvironmentFile= as root
        # before dropping privileges, so root:root 0400 (the default) works.
      };

      # Not behind oauth2-proxy: atticd has its own JWT auth and CI must reach
      # the push API with a bearer token, not a browser SSO flow.
      services.nginx.virtualHosts."${domain}" = fpLib.mkVirtualHost {
        inherit port;
        extraConfig = ''
          client_max_body_size 1G;
        '';
      };

      services.postgresql = fpLib.mkPostgresDB {
        name = "atticd";
        login = true;
      };

      services.atticd = {
        enable = true;
        environmentFile = config.age.secrets.atticd-env.path;
        settings = {
          listen = "127.0.0.1:${toString port}";
          database.url = "postgresql:///atticd?host=/run/postgresql";
          storage = {
            type = "local";
            path = "/var/lib/atticd/storage";
          };
          chunking = {
            nar-size-threshold = 65536;
            min-size = 16384;
            avg-size = 65536;
            max-size = 262144;
          };
          garbage-collection = {
            interval = "2 days";
            default-retention-period = "7 days";
          };
        };
      };
    };
  };
}
