{
  flake.modules.nixos.nginx = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.fireproof.homelab;
  in {
    config = lib.mkIf config.fireproof.homelab.enable {
      networking.firewall.allowedTCPPorts = [80 443];

      services.nginx = {
        enable = true;
        recommendedTlsSettings = true;
        recommendedOptimisation = true;
        recommendedProxySettings = true;
        recommendedGzipSettings = true;
        recommendedBrotliSettings = true;

        virtualHosts."status.localhost" = {
          listen = [
            {
              addr = "127.0.0.1";
              port = 8070;
            }
          ];
          locations."/metrics" = {
            extraConfig = ''
              stub_status;
              access_log off;
              allow 127.0.0.1;
              allow ::1;
              deny all;
            '';
          };
        };
      };
      security.acme = {
        acceptTerms = true;
        defaults.email = cfg.acmeEmail;
      };

      # Per-domain TLS expiry gauge, read straight from the ACME certs (no network
      # probe / hairpin-NAT dependency). The Grafana cert-expiry alert is the backstop
      # for a silently-broken renewal.
      systemd.services.cert-expiry-gauge = {
        description = "Write ACME cert expiry timestamps for node_exporter";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe (pkgs.writeShellApplication {
            name = "cert-expiry-gauge";
            runtimeInputs = [pkgs.openssl pkgs.coreutils];
            text = ''
              dir=/var/lib/node-exporter-textfile
              out="$dir/cert-expiry.prom.tmp"
              : >"$out"
              for cert in /var/lib/acme/*/cert.pem; do
                [ -e "$cert" ] || continue
                domain=$(basename "$(dirname "$cert")")
                end=$(openssl x509 -enddate -noout -in "$cert" | cut -d= -f2)
                printf 'homelab_cert_expiry_timestamp_seconds{domain="%s"} %s\n' \
                  "$domain" "$(date -d "$end" +%s)" >>"$out"
              done
              mv "$out" "$dir/cert-expiry.prom"
            '';
          });
        };
      };
      systemd.timers.cert-expiry-gauge = {
        wantedBy = ["timers.target"];
        timerConfig = {
          OnCalendar = "daily";
          Persistent = true;
        };
      };
    };
  };
}
