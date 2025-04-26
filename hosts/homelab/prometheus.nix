{
  config,
  hostname,
  ...
}: let
  mkScrapeConfig = name: {
    job_name = name;
    static_configs = [
      {
        labels = {
          instance = hostname;
        };

        targets = [
          "${toString config.services.prometheus.exporters.${name}.listenAddress}:${toString config.services.prometheus.exporters.${name}.port}"
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
    ];

    exporters.node = {
      enable = true;
      extraFlags = [
        "--web.disable-exporter-metrics"
      ];
    };
  };
}
