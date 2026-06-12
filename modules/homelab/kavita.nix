{
  config,
  lib,
  pkgs,
  fpLib,
  ...
}: let
  cfg = config.fireproof.homelab;
  domain = "kavita.${cfg.domain}";
  port = 5000;
  # TODO: move both to agenix — local files for now.
  tokenFile = "/var/lib/secrets/kavita-token";
  oidcSecretFile = "/var/lib/secrets/kavita-oidc-secret";
in {
  config = lib.mkIf cfg.enable {
    services.restic.backups.homelab.paths = [config.services.kavita.dataDir];

    # read the e-book/comic library provisioned by audiobookshelf.nix
    users.users.kavita.extraGroups = ["media"];

    services.nginx.virtualHosts."${domain}" = fpLib.mkVirtualHost {
      inherit port;
      websockets = true; # Kavita uses SignalR (WebSocket)
    };

    services.kavita = {
      enable = true;
      tokenKeyFile = tokenFile;
      settings = {
        Port = port;
        IpAddresses = "127.0.0.1";
        # Only Authority/ClientId/Secret/CustomScopes live in appsettings.json; the
        # behavioural toggles (provision accounts, role sync, disable-password, …)
        # are set in Kavita's web UI and persisted in its DB. The module rewrites
        # appsettings.json on every restart, so these must come from Nix or a switch
        # wipes them. @OIDC_SECRET@ is spliced from oidcSecretFile in preStart below.
        OpenIdConnectSettings = {
          Authority = "https://sso.${cfg.domain}";
          ClientId = "377132054418096139";
          Secret = "@OIDC_SECRET@";
          CustomScopes = [];
        };
      };
    };

    # Splice the OIDC client secret in without it ever entering the nix store —
    # same pattern the upstream module uses for tokenKeyFile (@TOKEN@).
    systemd.services.kavita = {
      serviceConfig.LoadCredential = ["oidc-secret:${oidcSecretFile}"];
      preStart = lib.mkAfter ''
        ${pkgs.replace-secret}/bin/replace-secret '@OIDC_SECRET@' \
          "$CREDENTIALS_DIRECTORY/oidc-secret" \
          '${config.services.kavita.dataDir}/config/appsettings.json'
      '';
    };
  };
}
