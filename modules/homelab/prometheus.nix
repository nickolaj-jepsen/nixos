{
  # These exporters are scraped + remote_written to Grafana Cloud by Alloy
  # (modules/homelab/alloy.nix); there is no local Prometheus server.
  flake.modules.nixos.prometheus = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf config.fireproof.homelab.enable {
      # Drop-dir for node_exporter textfile gauges (restic freshness, qBittorrent
      # VPN probe, …). World-readable so the exporter reads what root writes.
      systemd.tmpfiles.rules = [
        "d /var/lib/node-exporter-textfile 0755 root root -"
      ];

      # All exporters bind loopback only; Alloy scrapes them from the same host.
      services.prometheus.exporters = {
        node = {
          enable = true;
          listenAddress = "127.0.0.1";
          enabledCollectors = ["systemd"];
          extraFlags = [
            "--web.disable-exporter-metrics"
            "--collector.textfile.directory=/var/lib/node-exporter-textfile"
          ];
        };
        nginx = {
          enable = true;
          listenAddress = "127.0.0.1";
          scrapeUri = "http://127.0.0.1:8070/metrics";
        };
        postgres = {
          enable = true;
          listenAddress = "127.0.0.1";
          runAsLocalSuperUser = true;
        };
        smartctl = {
          enable = true;
          listenAddress = "127.0.0.1";
        };
      };
    };
  };
}
