# Fleet monitoring.
#
# Two roles, both configured through `fireproof.monitoring`:
#
#   * agent  - runs on every host. Exposes a node-exporter (with the systemd
#              collector) on the Tailscale interface only, so the hub can scrape
#              it without any shared secret - the tailnet is the trust boundary.
#   * server - runs on the homelab host (see modules/homelab/monitoring). Scrapes
#              every host in `fireproof.monitoring.hosts`, stores locally, mirrors
#              to Grafana Cloud as an offsite copy, and serves Grafana + alerts.
{
  config,
  lib,
  ...
}: let
  cfg = config.fireproof.monitoring;
  agentCfg = cfg.agent;
in {
  options.fireproof.monitoring = {
    agent.enable =
      lib.mkEnableOption "exposing node metrics to the monitoring hub over Tailscale"
      // {default = true;};

    agent.interface = lib.mkOption {
      type = lib.types.str;
      default = "tailscale0";
      description = "Network interface the metrics endpoint is firewalled to. Only the hub, reachable over this interface, may scrape it.";
    };

    server.enable = lib.mkOption {
      type = lib.types.bool;
      default = config.fireproof.homelab.enable;
      description = "Run the central monitoring hub (Prometheus + Grafana + Alertmanager) on this host.";
    };

    domain = lib.mkOption {
      type = lib.types.str;
      default = config.fireproof.homelab.domain;
      description = "Root domain the hub's web UIs are served under (grafana.<domain>, ntfy.<domain>).";
    };

    retention = lib.mkOption {
      type = lib.types.str;
      default = "90d";
      description = "How long the hub keeps metrics locally.";
    };

    cloudBackup.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Mirror all metrics to Grafana Cloud via remote_write as a free offsite copy (visible even when homelab is down).";
    };

    alerts.enable = lib.mkOption {
      type = lib.types.bool;
      default = cfg.server.enable;
      description = "Run Alertmanager and route alerts to ntfy.";
    };

    ntfy.topic = lib.mkOption {
      type = lib.types.str;
      default = "homelab-alerts";
      description = "ntfy topic alerts are published to. Subscribe to it from the ntfy app.";
    };

    hosts = lib.mkOption {
      description = "Hosts the hub scrapes. Each is reached at <name>:<node port> over Tailscale (the host itself is scraped on localhost).";
      default = [
        {
          name = "homelab";
          tier = "infra";
        }
        {
          name = "minilab";
          tier = "infra";
        }
        {
          name = "desktop";
          tier = "workstation";
        }
        {
          name = "laptop";
          tier = "workstation";
        }
        {
          name = "work";
          tier = "workstation";
        }
      ];
      type = lib.types.listOf (lib.types.submodule {
        options = {
          name = lib.mkOption {
            type = lib.types.str;
            description = "Tailscale MagicDNS name of the host (matches its hostname).";
          };
          tier = lib.mkOption {
            type = lib.types.enum ["infra" "workstation"];
            default = "workstation";
            description = "infra hosts are always-on and page when down; workstations are best-effort and never page on being offline.";
          };
        };
      });
    };
  };

  config = lib.mkIf agentCfg.enable {
    services.prometheus.exporters.node = {
      enable = true;
      enabledCollectors = ["systemd"];
      extraFlags = ["--web.disable-exporter-metrics"];
    };

    # The exporter binds to all interfaces but is only reachable over the
    # tailnet - the hub scrapes it there, everything else is denied.
    networking.firewall.interfaces.${agentCfg.interface}.allowedTCPPorts = [
      config.services.prometheus.exporters.node.port
    ];
  };
}
