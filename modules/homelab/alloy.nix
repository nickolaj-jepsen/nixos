{
  flake.modules.nixos.alloy = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf config.fireproof.homelab.enable {
      # One env-file holds both Grafana Cloud push credentials (PROM_* + LOKI_*).
      # Alloy runs as a DynamicUser, so it can't read a chown'd secret directly;
      # systemd reads this EnvironmentFile as root and the config references the
      # values via sys.env("…").
      age.secrets.grafana-cloud-env.rekeyFile = ../../secrets/hosts/homelab/grafana-cloud-env.age;

      services.alloy = {
        enable = true;
        environmentFile = config.age.secrets.grafana-cloud-env.path;
      };

      environment.etc."alloy/config.alloy".text = ''
        // ── Metrics: scrape the local Prometheus exporters, remote_write to Grafana Cloud ──
        prometheus.scrape "node" {
          targets         = [{ __address__ = "127.0.0.1:9100" }]
          scrape_interval = "1m"
          forward_to      = [prometheus.relabel.homelab.receiver]
        }

        prometheus.scrape "nginx" {
          targets         = [{ __address__ = "127.0.0.1:9113" }]
          scrape_interval = "1m"
          forward_to      = [prometheus.relabel.homelab.receiver]
        }

        prometheus.scrape "postgres" {
          targets         = [{ __address__ = "127.0.0.1:9187" }]
          scrape_interval = "1m"
          forward_to      = [prometheus.relabel.homelab.receiver]
        }

        prometheus.scrape "smartctl" {
          targets         = [{ __address__ = "127.0.0.1:9633" }]
          scrape_interval = "1m"
          forward_to      = [prometheus.relabel.homelab.receiver]
        }

        prometheus.scrape "systemd" {
          targets         = [{ __address__ = "127.0.0.1:9558" }]
          scrape_interval = "1m"
          forward_to      = [prometheus.relabel.homelab.receiver]
        }

        prometheus.relabel "homelab" {
          rule {
            target_label = "instance"
            replacement  = "homelab"
          }
          forward_to = [prometheus.remote_write.grafana_cloud.receiver]
        }

        prometheus.remote_write "grafana_cloud" {
          endpoint {
            url = sys.env("PROM_URL")
            basic_auth {
              username = sys.env("PROM_USER")
              password = sys.env("PROM_TOKEN")
            }
          }
        }

        // ── Logs: ship the system journal to Grafana Cloud Loki ──
        loki.source.journal "system" {
          max_age    = "12h"
          labels     = { host = "homelab" }
          forward_to = [loki.relabel.journal.receiver]
        }

        loki.relabel "journal" {
          rule {
            source_labels = ["__journal__systemd_unit"]
            target_label  = "unit"
          }
          forward_to = [loki.write.grafana_cloud.receiver]
        }

        loki.write "grafana_cloud" {
          endpoint {
            url = sys.env("LOKI_URL")
            basic_auth {
              username = sys.env("LOKI_USER")
              password = sys.env("LOKI_TOKEN")
            }
          }
        }
      '';
    };
  };
}
