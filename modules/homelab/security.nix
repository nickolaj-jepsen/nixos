{
  flake.modules.nixos.homelab-security = {
    config,
    lib,
    ...
  }: let
    # nginx's access log is file-only, so these jails can't use the module's default systemd backend.
    accessLogJail = {
      enabled = true;
      port = "http,https";
      backend = "auto";
      logpath = "/var/log/nginx/access.log";
    };
  in {
    config = lib.mkIf config.fireproof.homelab.enable {
      services.fail2ban = {
        enable = true;
        maxretry = 5;
        ignoreIP = [
          "10.0.0.0/8"
          "172.16.0.0/12"
          "192.168.0.0/16"
          "100.64.0.0/10" # tailnet
        ];
        jails = {
          nginx-http-auth.settings = {
            enabled = true;
            port = "http,https";
          };
          nginx-botsearch.settings = accessLogJail;
          nginx-bad-request.settings = accessLogJail;
        };
      };
      # fail2ban refuses to start when a jail's logpath doesn't exist yet.
      systemd.services.fail2ban.after = ["nginx.service"];
    };
  };
}
