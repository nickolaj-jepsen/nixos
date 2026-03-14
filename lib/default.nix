{lib}: {
  mkVirtualHost = {
    port,
    host ? "127.0.0.1",
    websockets ? false,
    http2 ? false,
  }: {
    forceSSL = true;
    enableACME = true;
    inherit http2;
    locations."/" =
      {
        proxyPass = "http://${host}:${toString port}/";
      }
      // lib.optionalAttrs websockets {proxyWebsockets = true;};
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
