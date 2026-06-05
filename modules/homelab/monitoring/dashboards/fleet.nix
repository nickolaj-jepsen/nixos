# Fleet overview dashboard, defined as Nix -> JSON and provisioned read-only.
# Edit here and rebuild; to tweak in the UI, export the JSON and commit it back.
let
  ds = {
    type = "prometheus";
    uid = "prometheus";
  };

  target = expr: legend: {
    datasource = ds;
    inherit expr;
    legendFormat = legend;
    refId = "A";
  };

  stat = {
    id,
    title,
    x,
    expr,
    unit ? "none",
    color ? "text",
  }: {
    inherit id title;
    type = "stat";
    datasource = ds;
    gridPos = {
      h = 4;
      w = 8;
      inherit x;
      y = 0;
    };
    targets = [(target expr "")];
    fieldConfig = {
      defaults = {
        inherit unit;
        color.mode = color;
      };
      overrides = [];
    };
    options = {
      colorMode = "value";
      graphMode = "area";
      reduceOptions = {
        calcs = ["lastNotNull"];
        fields = "";
        values = false;
      };
    };
  };

  timeseries = {
    id,
    title,
    x,
    y,
    expr,
    legend ? "{{instance}}",
    unit ? "short",
  }: {
    inherit id title;
    type = "timeseries";
    datasource = ds;
    gridPos = {
      h = 8;
      w = 12;
      inherit x y;
    };
    targets = [(target expr legend)];
    fieldConfig = {
      defaults = {
        inherit unit;
        custom = {
          drawStyle = "line";
          fillOpacity = 10;
          showPoints = "never";
        };
      };
      overrides = [];
    };
    options = {
      legend = {
        displayMode = "table";
        placement = "bottom";
        calcs = ["lastNotNull" "max"];
      };
      tooltip.mode = "multi";
    };
  };
in {
  uid = "fleet-overview";
  title = "Fleet Overview";
  tags = ["nixos" "fleet"];
  schemaVersion = 39;
  version = 1;
  editable = true;
  timezone = "browser";
  refresh = "30s";
  time = {
    from = "now-6h";
    to = "now";
  };
  templating.list = [];
  annotations.list = [];
  panels = [
    (stat {
      id = 1;
      title = "Infra hosts up";
      x = 0;
      expr = "count(up{tier=\"infra\"} == 1)";
    })
    (stat {
      id = 2;
      title = "Failed systemd units";
      x = 8;
      expr = "sum(node_systemd_unit_state{state=\"failed\"}) or vector(0)";
    })
    (stat {
      id = 3;
      title = "Avg CPU busy";
      x = 16;
      unit = "percent";
      expr = "100 * (1 - avg(rate(node_cpu_seconds_total{mode=\"idle\"}[5m])))";
    })
    (timeseries {
      id = 10;
      title = "CPU busy % by host";
      x = 0;
      y = 4;
      unit = "percent";
      expr = "100 * (1 - avg by (instance) (rate(node_cpu_seconds_total{mode=\"idle\"}[5m])))";
    })
    (timeseries {
      id = 11;
      title = "Memory used % by host";
      x = 12;
      y = 4;
      unit = "percent";
      expr = "100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)";
    })
    (timeseries {
      id = 12;
      title = "Root disk used % by host";
      x = 0;
      y = 12;
      unit = "percent";
      expr = "100 * (1 - node_filesystem_avail_bytes{mountpoint=\"/\"} / node_filesystem_size_bytes{mountpoint=\"/\"})";
    })
    (timeseries {
      id = 13;
      title = "Load (1m) by host";
      x = 12;
      y = 12;
      expr = "node_load1";
    })
    (timeseries {
      id = 14;
      title = "Network received by host";
      x = 0;
      y = 20;
      unit = "Bps";
      expr = "sum by (instance) (rate(node_network_receive_bytes_total{device!~\"lo|veth.*|docker.*\"}[5m]))";
    })
    (timeseries {
      id = 15;
      title = "Network transmitted by host";
      x = 12;
      y = 20;
      unit = "Bps";
      expr = "sum by (instance) (rate(node_network_transmit_bytes_total{device!~\"lo|veth.*|docker.*\"}[5m]))";
    })
  ];
}
