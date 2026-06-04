{lib}: let
  # Monitor helpers, shared by the desktop modules (bar, desktop-widgets, niri
  # outputs). `config.monitors` is the list of submodules from
  # modules/desktop/monitors.nix. All helpers tolerate an empty list.
  # Monitors that aren't explicitly disabled (`enable = false`).
  activeMonitors = monitors: builtins.filter (m: m.enable) monitors;

  # The primary monitor: the entry flagged `primary = true`, else the first
  # active entry in list order. Returns {} when there are no active monitors,
  # so callers should guard with `primaryMonitor monitors != {}`.
  primaryMonitor = monitors: let
    active = activeMonitors monitors;
  in
    if active == []
    then {}
    else lib.findFirst (m: m.primary or false) (builtins.head active) active;

  primaryMonitorName = monitors: (primaryMonitor monitors).name or "";

  # Active monitors excluding the primary one.
  secondaryMonitors = monitors: let
    primary = primaryMonitor monitors;
  in
    builtins.filter (m: m != primary) (activeMonitors monitors);
in {
  inherit activeMonitors primaryMonitor primaryMonitorName secondaryMonitors;

  mkVirtualHost = {
    port,
    host ? "127.0.0.1",
    websockets ? false,
    http2 ? true,
    extraConfig ? "",
    extraLocations ? {},
  }: {
    forceSSL = true;
    enableACME = true;
    inherit http2;
    locations =
      {
        "/" =
          {
            proxyPass = "http://${host}:${toString port}/";
          }
          // lib.optionalAttrs websockets {proxyWebsockets = true;}
          // lib.optionalAttrs (extraConfig != "") {inherit extraConfig;};
      }
      // extraLocations;
  };

  mkPostgresDB = {
    name,
    login ? false,
    authentication ? null,
  }:
    {
      ensureDatabases = [name];
      ensureUsers = [
        (
          {
            inherit name;
            ensureDBOwnership = true;
          }
          // lib.optionalAttrs login {ensureClauses.login = true;}
        )
      ];
    }
    // lib.optionalAttrs (authentication != null) {inherit authentication;};
}
