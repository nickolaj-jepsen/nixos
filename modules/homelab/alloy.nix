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

      # OTLP in, over the docker bridge, same idiom as mariadb.nix: containers
      # reach it at host.docker.internal:4318 and the default deny still blocks
      # 4318 on the LAN/WAN NICs. HTTP rather than gRPC because a container
      # talking protobuf-over-HTTP needs no extra dependency and the OTLP
      # exporter meta-package carries both transports anyway.
      networking.firewall.interfaces."docker0".allowedTCPPorts = [4318];

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
          // Container logs reach the journal through dockerd, so every one of
          // them carries _SYSTEMD_UNIT=docker.service — indistinguishable from
          // each other and from the daemon without this. One underscore here,
          // not two: the journal field is CONTAINER_NAME, and the doubled one
          // above is only because _SYSTEMD_UNIT already starts with one.
          rule {
            source_labels = ["__journal_container_name"]
            target_label  = "container"
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

        // ── OTLP in: applications that push rather than being scraped ──
        // runite-podcast is the first. Its worker is a container with no
        // Prometheus endpoint to scrape (runite's pull endpoint is an unbuilt
        // gap), so metrics arrive here alongside its traces and logs.
        otelcol.receiver.otlp "default" {
          http { endpoint = "0.0.0.0:4318" }

          output {
            metrics = [otelcol.processor.batch.default.input]
            logs    = [otelcol.processor.batch.default.input]
          }
        }

        otelcol.processor.batch "default" {
          output {
            metrics = [otelcol.exporter.prometheus.otlp_metrics.input]
            logs    = [otelcol.exporter.loki.otlp_logs.input]
          }
        }

        // Converted to Prometheus and pushed down the same relabel rule the
        // scrapes use, so OTLP series carry instance="homelab" too.
        otelcol.exporter.prometheus "otlp_metrics" {
          forward_to = [prometheus.relabel.homelab.receiver]
        }

        otelcol.exporter.loki "otlp_logs" {
          forward_to = [loki.write.grafana_cloud.receiver]
        }

        // Traces are received but deliberately not forwarded: Grafana Cloud
        // Tempo needs its own endpoint and credentials, and grafana-cloud-env
        // holds only PROM_* and LOKI_*. Adding them is a manual step —
        // `just secret-edit secrets/hosts/homelab/grafana-cloud-env.age` with
        // TEMPO_URL/TEMPO_USER/TEMPO_TOKEN — after which this becomes an
        // otelcol.exporter.otlp block wired into the batch processor's
        // `traces` output. Referencing sys.env of an unset variable would fail
        // Alloy's config load and take the metrics and logs down with it.
      '';
    };
  };
}
