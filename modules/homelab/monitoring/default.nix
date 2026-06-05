# Monitoring hub (homelab): the central Prometheus server.
#
# Scrapes every host in `fireproof.monitoring.hosts` over Tailscale plus the
# homelab-local exporters (nginx, postgres, smartctl), keeps `retention` worth
# of data on disk, and - when cloudBackup is on - mirrors everything to Grafana
# Cloud so the fleet stays visible even if homelab itself goes down.
{
  config,
  lib,
  ...
}: let
  inherit (config.fireproof) hostname;
  cfg = config.fireproof.monitoring;

  nodePort = config.services.prometheus.exporters.node.port;

  # Each fleet host: scraped on localhost if it's us, otherwise via MagicDNS.
  hostAddress = host:
    if host.name == hostname
    then "127.0.0.1"
    else host.name;

  mkNodeScrape = host: {
    job_name = "node-${host.name}";
    static_configs = [
      {
        targets = ["${hostAddress host}:${toString nodePort}"];
        labels = {
          instance = host.name;
          inherit (host) tier;
        };
      }
    ];
  };

  # Homelab-local exporters that only listen on loopback.
  mkLocalScrape = name: {
    job_name = name;
    static_configs = [
      {
        targets = ["127.0.0.1:${toString config.services.prometheus.exporters.${name}.port}"];
        labels = {
          instance = hostname;
          tier = "infra";
        };
      }
    ];
  };
in {
  imports = [
    ./grafana.nix
    ./alerting.nix
  ];

  config = lib.mkIf cfg.server.enable {
    age.secrets.grafana-cloud-prometheus-api-key = {
      rekeyFile = ../../../secrets/grafana-cloud-prometheus.age;
      owner = "prometheus";
      group = "prometheus";
    };

    # Local exporters for homelab-only services.
    services.prometheus.exporters = {
      nginx = {
        enable = true;
        scrapeUri = "http://127.0.0.1:8070/metrics";
      };
      postgres = {
        enable = true;
        runAsLocalSuperUser = true;
      };
      smartctl.enable = config.fireproof.hardware.physical;
    };

    services.prometheus = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = 9090;
      retentionTime = cfg.retention;
      globalConfig.scrape_interval = "1m";

      remoteWrite = lib.mkIf cfg.cloudBackup.enable [
        {
          url = "https://prometheus-prod-01-eu-west-0.grafana.net/api/prom/push";
          basic_auth = {
            username = "432120";
            password_file = "${config.age.secrets.grafana-cloud-prometheus-api-key.path}";
          };
        }
      ];

      scrapeConfigs =
        (map mkNodeScrape cfg.hosts)
        ++ [
          (mkLocalScrape "nginx")
          (mkLocalScrape "postgres")
        ]
        ++ lib.optional config.fireproof.hardware.physical (mkLocalScrape "smartctl");
    };
  };
}
