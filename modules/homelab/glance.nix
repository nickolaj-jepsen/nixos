{
  config,
  lib,
  pkgs,
  ...
}:
lib.mkIf config.fireproof.homelab.enable (let
  domain = "glance.nickolaj.com";
  port = 8088;

  customCss = pkgs.writeText "glance-custom.css" ''
    .bookmarks-group li > div {
      background-color: var(--color-background);
      margin-top: 5px;
      border-radius: var(--border-radius);
      transition: background-color 0.3s;
      font-size: 1.2em;
      padding-left: 5px;
    }

    .bookmarks-group li > div:has(a:hover) {
      background-color: var(--color-widget-background-highlight);
    }

    .bookmarks-group li a {
      padding: 10px 0;
      width: 100%;
    }
  '';
in {
  age.secrets.glance-env.rekeyFile = ../../secrets/hosts/homelab/glance-env.age;

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
        background-color = "30 4 11"; # #1C1B1A (HSL)
        primary-color = "14 56 55"; # #CF6A4C accent (HSL)
        positive-color = "72 59 38"; # #879A39 green (HSL)
        negative-color = "5 64 54"; # #D14D41 red (HSL)
        contrast-multiplier = 1.1;
        text-saturation-multiplier = 1.0;
        custom-css-file = "https://${domain}/custom.css";
        disable-picker = true;
      };
      branding = {
        hide-footer = true;
      };
      pages = [
        {
          name = "Home";
          columns = [
            {
              size = "small";
              widgets = [
                {
                  type = "calendar";
                  first-day-of-week = "monday";
                }
                {
                  type = "weather";
                  title = "Weather";
                  location = "\${WEATHER_LOCATION}";
                  units = "metric";
                }
                {
                  type = "server-stats";
                  servers = [
                    {
                      type = "local";
                      name = "Home Server";
                    }
                  ];
                }
              ];
            }
            {
              size = "full";
              widgets = [
                {
                  type = "bookmarks";
                  title = "Applications";
                  groups = [
                    {
                      title = "Social";
                      links = [
                        {
                          title = "Gmail";
                          url = "https://mail.google.com";
                          icon = "si:gmail";
                          same-tab = true;
                        }
                        {
                          title = "Reddit";
                          url = "https://reddit.com";
                          icon = "si:reddit";
                          same-tab = true;
                        }
                        {
                          title = "Github";
                          url = "https://github.com";
                          icon = "si:github";
                          same-tab = true;
                        }
                      ];
                    }
                    {
                      title = "NixOS";
                      links = [
                        {
                          title = "NixOS Search";
                          url = "https://search.nixos.org";
                          icon = "si:nixos";
                          same-tab = true;
                        }
                        {
                          title = "Home-manager Search";
                          url = "https://home-manager-options.extranix.com";
                          icon = "si:nixos";
                          same-tab = true;
                        }
                        {
                          title = "Noogle";
                          url = "https://noogle.dev";
                          icon = "si:nixos";
                          same-tab = true;
                        }
                      ];
                    }
                    {
                      title = "Streaming";
                      links = [
                        {
                          title = "YouTube";
                          url = "https://youtube.com";
                          icon = "si:youtube";
                          same-tab = true;
                        }
                        {
                          title = "Netflix";
                          url = "https://netflix.com";
                          icon = "si:netflix";
                          same-tab = true;
                        }
                        {
                          title = "HBO Max";
                          url = "https://play.max.com";
                          icon = "si:hbo";
                          same-tab = true;
                        }
                        {
                          title = "Disney Plus";
                          url = "https://disneyplus.com";
                          icon = "mdi:castle";
                          same-tab = true;
                        }
                      ];
                    }
                  ];
                }
                {
                  type = "monitor";
                  cache = "5m";
                  sites = [
                    {
                      title = "Home Assistant";
                      url = "https://ha.nickolaj.com";
                      icon = "sh:home-assistant";
                      same-tab = true;
                    }
                    {
                      title = "Zigbee2MQTT";
                      url = "https://zigbee.nickolaj.com";
                      icon = "sh:zigbee2mqtt";
                      same-tab = true;
                    }
                    {
                      title = "Nextcloud";
                      url = "https://nextcloud.nickolaj.com";
                      icon = "sh:nextcloud";
                      same-tab = true;
                    }
                    {
                      title = "Plex";
                      url = "https://plex.nickolaj.com";
                      icon = "sh:plex";
                      same-tab = true;
                      alt-status-codes = [401];
                    }
                    {
                      title = "Jellyfin";
                      url = "https://jellyfin.nickolaj.com";
                      icon = "sh:jellyfin";
                      same-tab = true;
                    }
                    {
                      title = "Sonarr";
                      url = "https://sonarr.nickolaj.com";
                      icon = "sh:sonarr";
                      same-tab = true;
                    }
                    {
                      title = "Radarr";
                      url = "https://radarr.nickolaj.com";
                      icon = "sh:radarr";
                      same-tab = true;
                    }
                    {
                      title = "SABnzbd";
                      url = "https://sabnzbd.nickolaj.com";
                      icon = "sh:sabnzbd";
                      same-tab = true;
                    }
                    {
                      title = "Zitadel";
                      url = "https://sso.nickolaj.com";
                      icon = "sh:zitadel";
                      same-tab = true;
                    }
                  ];
                }
                {
                  type = "group";
                  widgets = [
                    {
                      type = "hacker-news";
                      collapse-after = 10;
                      limit = 20;
                    }
                    {
                      type = "rss";
                      style = "detailed-list";
                      title-url = "https://www.inoreader.com/all_articles";
                      feeds = [
                        {
                          title = "Inoreader";
                          url = "https://www.inoreader.com/stream/user/1004648594/tag/all-articles";
                        }
                      ];
                    }
                    {
                      type = "reddit";
                      subreddit = "simracing";
                      show-thumbnails = true;
                      collapse-after = 10;
                      comments-url-template = "https://old.reddit.com/{POST-PATH}";
                      title-url = "https://old.reddit.com/r/simracing";
                    }
                    {
                      type = "reddit";
                      subreddit = "iracing";
                      show-thumbnails = true;
                      collapse-after = 10;
                      comments-url-template = "https://old.reddit.com/{POST-PATH}";
                      title-url = "https://old.reddit.com/r/iracing";
                    }
                    {
                      type = "reddit";
                      subreddit = "formula1";
                      show-thumbnails = true;
                      collapse-after = 10;
                      comments-url-template = "https://old.reddit.com/{POST-PATH}";
                      title-url = "https://old.reddit.com/r/formula1";
                    }
                    {
                      type = "reddit";
                      subreddit = "denmark";
                      show-thumbnails = true;
                      collapse-after = 10;
                      comments-url-template = "https://old.reddit.com/{POST-PATH}";
                      title-url = "https://old.reddit.com/r/denmark";
                    }
                  ];
                }
              ];
            }
          ];
        }
        {
          name = "Work";
          columns = [
            {
              size = "small";
              widgets = [
                {
                  type = "clock";
                  title = "Clock";
                  timezone = "Europe/Copenhagen";
                }
                {
                  type = "weather";
                  title = "Weather";
                  location = "\${WEATHER_LOCATION}";
                  units = "metric";
                }
                {
                  type = "calendar";
                  first-day-of-week = "monday";
                }
              ];
            }
            {
              size = "full";
              widgets = [
                {
                  type = "bookmarks";
                  title = "Applications";
                  groups = [
                    {
                      title = "Comunication";
                      links = [
                        {
                          title = "Outlook";
                          url = "https://outlook.office.com";
                          icon = "si:microsoftoutlook";
                          same-tab = true;
                        }
                        {
                          title = "Teams";
                          url = "https://teams.microsoft.com";
                          icon = "si:microsoftteams";
                          same-tab = true;
                        }
                        {
                          title = "Slack";
                          url = "https://slack.com";
                          icon = "si:slack";
                          same-tab = true;
                        }
                        {
                          title = "Linear";
                          url = "https://linear.app";
                          icon = "si:linear";
                          same-tab = true;
                        }
                      ];
                    }
                    {
                      title = "Infra";
                      links = [
                        {
                          title = "Grafana";
                          url = "\${URL_GRAFANA}";
                          icon = "si:grafana";
                          same-tab = true;
                        }
                        {
                          title = "Scaleway";
                          url = "https://console.scaleway.com";
                          icon = "si:scaleway";
                          same-tab = true;
                        }
                        {
                          title = "Growthbook";
                          url = "https://app.growthbook.io";
                          icon = "mdi:ab-testing";
                          same-tab = true;
                        }
                        {
                          title = "Metabase";
                          url = "\${URL_METABASE}";
                          icon = "si:metabase";
                          same-tab = true;
                        }
                        {
                          title = "Dagster";
                          url = "https://ao.eu.dagster.cloud";
                          icon = "mdi:format-list-checks";
                          same-tab = true;
                        }
                      ];
                    }
                    {
                      title = "Development";
                      links = [
                        {
                          title = "GitHub";
                          url = "https://github.com";
                          icon = "si:github";
                          same-tab = true;
                        }
                        {
                          title = "Copilot";
                          url = "https://github.com/copilot";
                          icon = "si:githubcopilot";
                          same-tab = true;
                        }
                        {
                          title = "ArgoCD";
                          url = "\${URL_ARGOCD}";
                          icon = "si:argo";
                          same-tab = true;
                        }
                        {
                          title = "ArgoCD (Dev)";
                          url = "\${URL_ARGOCD_DEV}";
                          icon = "si:argo";
                          same-tab = true;
                        }
                      ];
                    }
                  ];
                }
                {
                  type = "split-column";
                  widgets = [
                    {
                      type = "hacker-news";
                      collapse-after = 10;
                    }
                    {
                      type = "rss";
                      collapse-after = 10;
                      title-url = "https://www.inoreader.com/all_articles";
                      feeds = [
                        {
                          title = "Inoreader";
                          url = "https://www.inoreader.com/stream/user/1004648594/tag/all-articles";
                        }
                      ];
                    }
                  ];
                }
              ];
            }
          ];
        }
      ];
    };
  };

  services.oauth2-proxy.nginx.virtualHosts."${domain}".allowed_groups = ["default"];

  services.nginx.virtualHosts."${domain}" = {
    enableACME = true;
    forceSSL = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString port}";
    };
    locations."= /custom.css" = {
      alias = customCss;
      extraConfig = ''
        add_header Content-Type text/css;
      '';
    };
  };
})
