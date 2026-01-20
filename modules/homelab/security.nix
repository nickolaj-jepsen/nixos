{
  config,
  lib,
  ...
}:
lib.mkIf config.fireproof.homelab.enable {
  services.fail2ban = {
    enable = true;
    maxretry = 5;
    ignoreIP = [
      "127.0.0.1/8"
      "10.0.0.0/8"
      "172.16.0.0/12"
      "192.168.0.0/16"
    ];
    jails = {
      nginx-http-auth.settings = {
        enabled = true;
        filter = "nginx-http-auth";
        port = "http,https";
        logpath = "/var/log/nginx/error.log";
      };
      nginx-botsearch.settings = {
        enabled = true;
        filter = "nginx-botsearch";
        port = "http,https";
        logpath = "/var/log/nginx/error.log";
      };
      nginx-bad-request.settings = {
        enabled = true;
        port = "http,https";
        logpath = "/var/log/nginx/error.log";
      };
    };
  };
}
