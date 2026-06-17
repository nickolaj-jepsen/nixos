{
  flake.modules.nixos.glance = {
    config,
    pkgs,
    fpLib,
    ...
  }: let
    inherit (config.fireproof.theme) hsl;
    cfg = config.fireproof.homelab;
    domain = "glance.${cfg.domain}";
    port = 8088;

    customCss = pkgs.writeText "glance-custom.css" (builtins.readFile ./templates/custom.css);

    templates = {
      recent-repos = builtins.readFile ./templates/recent-repos.tpl;
      prs-awaiting-review = builtins.readFile ./templates/prs-awaiting-review.tpl;
      my-pull-requests = builtins.readFile ./templates/my-pull-requests.tpl;
    };

    homePage = import ./_home-page.nix {inherit cfg;};
    workPage = import ./_work-page.nix {inherit templates;};
  in {
    config = {
      age.secrets.glance-env.rekeyFile = ../../../secrets/hosts/homelab/glance-env.age;

      services.glance = {
        enable = true;
        environmentFile = config.age.secrets.glance-env.path;
        settings = {
          server = {
            inherit port;
            host = "127.0.0.1";
            base-url = "https://${domain}";
          };
          theme = {
            background-color = hsl.bg;
            primary-color = hsl.accent;
            positive-color = hsl.green;
            negative-color = hsl.red;
            contrast-multiplier = 1.1;
            text-saturation-multiplier = 1.0;
            custom-css-file = "https://${domain}/custom.css";
            disable-picker = true;
          };
          branding = {
            hide-footer = true;
          };
          pages = [homePage workPage];
        };
      };

      services.oauth2-proxy.nginx.virtualHosts."${domain}".allowed_groups = ["default"];

      services.nginx.virtualHosts."${domain}" = fpLib.mkVirtualHost {
        inherit port;
        extraLocations."= /custom.css" = {
          alias = customCss;
          extraConfig = ''
            add_header Content-Type text/css;
          '';
        };
      };
    };
  };
}
