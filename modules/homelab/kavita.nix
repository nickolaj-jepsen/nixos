{
  flake.modules.nixos.kavita = {
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
    config = lib.mkIf config.fireproof.homelab.enable {
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
          # Module rewrites appsettings.json every restart, so OIDC config must come from Nix or a switch wipes it.
          OpenIdConnectSettings = {
            Authority = "https://sso.${cfg.domain}";
            ClientId = "377132054418096139";
            Secret = "@OIDC_SECRET@";
            CustomScopes = [];
          };
        };
      };

      # Splice OIDC secret in at runtime so it never enters the nix store.
      systemd.services.kavita = {
        serviceConfig.LoadCredential = ["oidc-secret:${oidcSecretFile}"];
        preStart = lib.mkAfter ''
          ${pkgs.replace-secret}/bin/replace-secret '@OIDC_SECRET@' \
            "$CREDENTIALS_DIRECTORY/oidc-secret" \
            '${config.services.kavita.dataDir}/config/appsettings.json'
        '';
      };
    };
  };
}
