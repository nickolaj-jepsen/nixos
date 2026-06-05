# Alerting for the monitoring hub: Prometheus rules -> Alertmanager -> ntfy.
#
# ntfy is self-hosted (ntfy.<domain>); Alertmanager posts to a tiny stdlib relay
# that reshapes the webhook into an ntfy notification with sensible priority.
{
  config,
  lib,
  pkgs,
  fpLib,
  ...
}: let
  cfg = config.fireproof.monitoring;
  ntfyDomain = "ntfy.${cfg.domain}";
  ntfyPort = 2586;
  relayPort = 9098;

  relay = pkgs.writeText "alertmanager-ntfy.py" ''
    import http.server, json, os, urllib.request

    NTFY_URL = os.environ["NTFY_URL"]
    PORT = int(os.environ.get("LISTEN_PORT", "9098"))
    PRIORITY = {"critical": "urgent", "warning": "high", "info": "default"}


    class Handler(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            length = int(self.headers.get("Content-Length", "0"))
            raw = self.rfile.read(length) if length else b"{}"
            try:
                payload = json.loads(raw)
            except Exception:
                payload = {}
            for alert in payload.get("alerts", []):
                self.forward(alert)
            self.send_response(204)
            self.end_headers()

        def forward(self, alert):
            status = alert.get("status", "firing")
            labels = alert.get("labels", {})
            ann = alert.get("annotations", {})
            severity = labels.get("severity", "info")
            title = ann.get("summary", labels.get("alertname", "alert"))
            body = ann.get("description", labels.get("instance", ""))
            if status == "resolved":
                title = "[RESOLVED] " + title
                priority, tags = "min", "white_check_mark"
            else:
                priority = PRIORITY.get(severity, "default")
                tags = "rotating_light" if severity == "critical" else "warning"
            req = urllib.request.Request(
                NTFY_URL,
                data=body.encode("utf-8"),
                headers={"Title": title, "Priority": priority, "Tags": tags},
            )
            try:
                urllib.request.urlopen(req, timeout=10)
            except Exception as exc:
                print("ntfy relay error:", exc, flush=True)

        def log_message(self, *args):
            pass


    http.server.HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
  '';
in {
  config = lib.mkIf cfg.alerts.enable {
    # Alert rules - validated by promtool at build time.
    services.prometheus.rules = [
      (builtins.toJSON {
        groups = [
          {
            name = "fleet";
            rules = [
              {
                alert = "InstanceDown";
                expr = "up{tier=\"infra\"} == 0";
                "for" = "5m";
                labels.severity = "critical";
                annotations = {
                  summary = "{{ $labels.instance }} is down";
                  description = "{{ $labels.instance }} ({{ $labels.job }}) has been unreachable for 5m.";
                };
              }
              {
                alert = "SystemdUnitFailed";
                expr = "node_systemd_unit_state{state=\"failed\"} == 1";
                "for" = "10m";
                labels.severity = "warning";
                annotations = {
                  summary = "Failed unit on {{ $labels.instance }}";
                  description = "{{ $labels.name }} is in a failed state.";
                };
              }
              {
                alert = "DiskSpaceLow";
                expr = "(node_filesystem_avail_bytes{fstype!~\"tmpfs|overlay|ramfs\"} / node_filesystem_size_bytes{fstype!~\"tmpfs|overlay|ramfs\"}) < 0.10";
                "for" = "15m";
                labels.severity = "warning";
                annotations = {
                  summary = "Low disk space on {{ $labels.instance }}";
                  description = "{{ $labels.mountpoint }} has {{ $value | humanizePercentage }} free.";
                };
              }
              {
                alert = "DiskWillFillSoon";
                expr = "predict_linear(node_filesystem_avail_bytes{fstype!~\"tmpfs|overlay|ramfs\"}[6h], 24 * 3600) < 0";
                "for" = "1h";
                labels.severity = "warning";
                annotations = {
                  summary = "{{ $labels.mountpoint }} on {{ $labels.instance }} is filling up";
                  description = "Projected to run out of space within 24h at the current rate.";
                };
              }
              {
                alert = "MemoryPressure";
                expr = "(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) > 0.90";
                "for" = "15m";
                labels.severity = "warning";
                annotations = {
                  summary = "High memory usage on {{ $labels.instance }}";
                  description = "Available memory has been below 10% for 15m.";
                };
              }
            ];
          }
        ];
      })
    ];

    services.prometheus.alertmanagers = [
      {static_configs = [{targets = ["127.0.0.1:9093"];}];}
    ];

    services.prometheus.alertmanager = {
      enable = true;
      port = 9093;
      configuration = {
        route = {
          receiver = "ntfy";
          group_by = ["alertname" "instance"];
          group_wait = "30s";
          group_interval = "5m";
          repeat_interval = "4h";
        };
        receivers = [
          {
            name = "ntfy";
            webhook_configs = [
              {
                url = "http://127.0.0.1:${toString relayPort}/";
                send_resolved = true;
              }
            ];
          }
        ];
      };
    };

    systemd.services.alertmanager-ntfy = {
      description = "Relay Alertmanager webhooks to ntfy";
      after = ["network.target" "ntfy-sh.service"];
      wantedBy = ["multi-user.target"];
      environment = {
        NTFY_URL = "http://127.0.0.1:${toString ntfyPort}/${cfg.ntfy.topic}";
        LISTEN_PORT = toString relayPort;
      };
      serviceConfig = {
        ExecStart = "${pkgs.python3}/bin/python3 ${relay}";
        DynamicUser = true;
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };

    services.ntfy-sh = {
      enable = true;
      settings = {
        base-url = "https://${ntfyDomain}";
        listen-http = "127.0.0.1:${toString ntfyPort}";
        behind-proxy = true;
      };
    };

    services.nginx.virtualHosts."${ntfyDomain}" = fpLib.mkVirtualHost {
      port = ntfyPort;
      websockets = true;
    };
  };
}
