{
  config,
  lib,
  ...
}: let
  rootDomain = "nickolaj.com";
  zitadelDomain = "sso.${rootDomain}";
  oathproxyDomain = "oauth2-proxy.${rootDomain}";
in {
  config = lib.mkIf config.fireproof.homelab.enable {
    age.secrets.oauth2-proxy = {
      rekeyFile = ../../../secrets/hosts/homelab/oauth2-proxy-keyfile.age;
      owner = "oauth2-proxy";
    };

    services.nginx.virtualHosts."${oathproxyDomain}" = {
      enableACME = true;
      forceSSL = true;
      locations."/" = {
        proxyWebsockets = true;
        proxyPass = "http://127.0.0.1:4180";
      };
    };

    services.oauth2-proxy = {
      enable = true;
      provider = "oidc";
      reverseProxy = true;
      redirectURL = "https://${oathproxyDomain}/oauth2/callback";
      validateURL = "https://${zitadelDomain}/oauth2/";
      oidcIssuerUrl = "https://${zitadelDomain}:443";
      keyFile = config.age.secrets.oauth2-proxy.path;
      passBasicAuth = true;
      setXauthrequest = true;
      nginx.domain = oathproxyDomain;
      email.domains = ["*"];
      extraConfig = {
        whitelist-domain = ".${rootDomain}";
        cookie-domain = ".${rootDomain}";
      };
    };

    systemd.services.oauth2-proxy.serviceConfig = {
      Restart = "always";
      RestartSec = "5s";
    };
  };
}
