{lib}: let
  activeMonitors = monitors: builtins.filter (m: m.enable) monitors;

  # Returns {} when no active monitors; guard with `primaryMonitor monitors != {}`.
  primaryMonitor = monitors: let
    active = activeMonitors monitors;
  in
    if active == []
    then {}
    else lib.findFirst (m: m.primary or false) (builtins.head active) active;

  primaryMonitorName = monitors: (primaryMonitor monitors).name or "";

  secondaryMonitors = monitors: let
    primary = primaryMonitor monitors;
  in
    builtins.filter (m: m != primary) (activeMonitors monitors);
in {
  inherit primaryMonitor primaryMonitorName secondaryMonitors;

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

  # Split store (.rekey/.rekey-hm): `agenix rekey` deletes files a node doesn't own in its localStorageDir, so the host's two nodes must not share a dir.
  mkAgenixRekey = {
    hostname,
    store,
  }: let
    hostSecrets = ../secrets/hosts + ("/" + hostname);
  in {
    storageMode = "local";
    hostPubkey = builtins.readFile (hostSecrets + "/id_ed25519.pub");
    masterIdentities = [{identity = ../secrets/yubikey-identity.pub;}];
    extraEncryptionPubkeys = [
      "age1pzrfw28f8qvsk9g8p2stundf4ph466jut0g6q47sse76zljtqy9q2w32zr" # Backup key (bitwarden)
    ];
    localStorageDir = hostSecrets + ("/" + store);
    generatedSecretsDir = hostSecrets;
  };

  # Hex color -> "H S L" string (hue 0-360, sat/light 0-100, rounded) that Glance's theme expects.
  hexToHsl = hexInput: let
    hex = lib.removePrefix "#" hexInput;
    digit = c:
      {
        "0" = 0;
        "1" = 1;
        "2" = 2;
        "3" = 3;
        "4" = 4;
        "5" = 5;
        "6" = 6;
        "7" = 7;
        "8" = 8;
        "9" = 9;
        "a" = 10;
        "b" = 11;
        "c" = 12;
        "d" = 13;
        "e" = 14;
        "f" = 15;
      }
      .${
        lib.toLower c
      };
    byteAt = i: digit (builtins.substring i 1 hex) * 16 + digit (builtins.substring (i + 1) 1 hex);
    r = byteAt 0 / 255.0;
    g = byteAt 2 / 255.0;
    b = byteAt 4 / 255.0;
    maxc = lib.max r (lib.max g b);
    minc = lib.min r (lib.min g b);
    delta = maxc - minc;
    l = (maxc + minc) / 2;
    s =
      if delta == 0
      then 0
      else if l > 0.5
      then delta / (2 - maxc - minc)
      else delta / (maxc + minc);
    hue =
      if delta == 0
      then 0
      else if maxc == r
      then 60 * ((g - b) / delta)
      else if maxc == g
      then 60 * ((b - r) / delta + 2)
      else 60 * ((r - g) / delta + 4);
    h =
      if hue < 0
      then hue + 360
      else hue;
    round = x: builtins.floor (x + 0.5);
  in "${toString (round h)} ${toString (round (s * 100))} ${toString (round (l * 100))}";
}
