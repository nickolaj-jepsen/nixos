{
  config,
  lib,
  ...
}:
lib.mkIf config.fireproof.homelab.enable (let
  inherit (config.fireproof) hostname;
  mkScrapeConfig = name: {
    job_name = name;
    static_configs = [
      {
        labels = {
          instance = hostname;
        };

        targets = [
          "127.0.0.1:${toString config.services.prometheus.exporters.${name}.port}"
        ];
      }
    ];
  };
in {
  age.secrets.grafana-cloud-prometheus-api-key = {
    rekeyFile = ../../secrets/grafana-cloud-prometheus.age;
    owner = "prometheus";
    group = "prometheus";
  };

  services.prometheus = {
    enable = true;
    enableAgentMode = true;
    globalConfig.scrape_interval = "1m";
    remoteWrite = [
      {
        url = "https://prometheus-prod-01-eu-west-0.grafana.net/api/prom/push";
        basic_auth = {
          username = "432120";
          password_file = "${config.age.secrets.grafana-cloud-prometheus-api-key.path}";
        };
      }
    ];

    scrapeConfigs = [
      (mkScrapeConfig "node")
      (mkScrapeConfig "nginx")
      (mkScrapeConfig "postgres")
    ];

    exporters = {
      node = {
        enable = true;
        extraFlags = [
          "--web.disable-exporter-metrics"
        ];
      };
      nginx = {
        enable = true;
        scrapeUri = "http://127.0.0.1:8070/metrics";
      };
      postgres = {
        enable = true;
        runAsLocalSuperUser = true;
      };
    };
  };
})
