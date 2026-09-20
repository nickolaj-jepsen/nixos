{fpLib, ...}: {
  flake.modules.nixos.sso-proxy = {
    config,
    lib,
    pkgs,
    ...
  }: let
    rootDomain = config.fireproof.homelab.domain;
    zitadelDomain = "sso.${rootDomain}";
    oathproxyDomain = "oauth2-proxy.${rootDomain}";
  in {
    config = lib.mkIf config.fireproof.homelab.enable {
      age.secrets.oauth2-proxy = {
        rekeyFile = ../../../secrets/hosts/homelab/oauth2-proxy-keyfile.age;
        owner = "oauth2-proxy";
      };

      services.nginx.virtualHosts."${oathproxyDomain}" = fpLib.mkVirtualHost {
        port = 4180;
        websockets = true;
      };

      services.oauth2-proxy = {
        enable = true;
        provider = "oidc";
        reverseProxy = true;
        trustedProxyIP = ["127.0.0.1" "::1"];
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

      # oauth2-proxy exits on the first OIDC discovery failure and zitadel listens ~20 s
      # after "Started", which made every switch end in "units failed". Poll for 2 min.
      systemd.services.oauth2-proxy = {
        after = ["zitadel.service" "nginx.service"];
        wants = ["zitadel.service"];
        # Without a start limit the ~125 s probe-plus-restart cycle never accumulates
        # inside systemd's default 10 s window, so a genuinely broken zitadel would spin
        # forever while the unit still reported "running" instead of failing.
        startLimitIntervalSec = 900;
        startLimitBurst = 5;
        serviceConfig = {
          Restart = "always";
          RestartSec = "5s";
          TimeoutStartSec = "3min";
          ExecStartPre = lib.getExe (pkgs.writeShellApplication {
            name = "oauth2-proxy-wait-for-zitadel";
            runtimeInputs = [pkgs.curl pkgs.coreutils];
            text = ''
              # --max-time keeps the loop inside TimeoutStartSec: curl's default connect
              # timeout is 300 s, so one black-holed attempt would outlast the unit.
              for _ in $(seq 1 60); do
                curl -fsS --max-time 5 -o /dev/null "https://${zitadelDomain}/.well-known/openid-configuration" && exit 0
                sleep 2
              done
              echo "zitadel not reachable after 120 s, starting anyway" >&2
            '';
          });
        };
      };
    };
  };
}
