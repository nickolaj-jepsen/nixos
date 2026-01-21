{
  config,
  lib,
  pkgs,
  ...
}:
lib.mkIf config.fireproof.homelab.enable (let
  domain = "forgejo.nickolaj.com";
in {
  age.secrets.forgejo-runner-token = {
    rekeyFile = ../../secrets/hosts/homelab/forgejo-runner-token.age;
    mode = "0600";
  };

  services.forgejo = {
    enable = true;
    database.type = "postgres";
    dump = {
      enable = true;
      interval = "daily";
    };
    settings = {
      server = {
        DOMAIN = domain;
        ROOT_URL = "https://${domain}/";
        HTTP_PORT = 3000;
        HTTP_ADDR = "127.0.0.1";
      };
      service = {
        DISABLE_REGISTRATION = true;
        ENABLE_INTERNAL_SIGNIN = false;
      };
      actions = {
        ENABLED = true;
      };
    };
  };

  services.gitea-actions-runner = {
    package = pkgs.forgejo-runner;
    instances.homelab = {
      enable = true;
      name = "homelab";
      url = "https://${domain}";
      tokenFile = config.age.secrets.forgejo-runner-token.path;
      labels = [
        "ubuntu-latest:docker://node:20-bookworm"
      ];
    };
  };
  systemd.services.gitea-runner-default.serviceConfig.DynamicUser = lib.mkForce false;

  services.postgresql = {
    ensureDatabases = ["forgejo"];
    ensureUsers = [
      {
        name = "forgejo";
        ensureDBOwnership = true;
      }
    ];
  };

  services.restic.backups.homelab.paths = [
    config.services.forgejo.stateDir
    config.services.forgejo.dump.backupDir
  ];

  services.nginx.virtualHosts."${domain}" = {
    enableACME = true;
    forceSSL = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:3000";
    };
  };
})
