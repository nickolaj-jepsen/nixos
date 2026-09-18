{
  cfg,
  templates,
}: let
  url = sub: "https://${sub}.${cfg.domain}";
  site = {
    title,
    sub,
    icon,
    ...
  } @ args:
    {
      inherit title icon;
      url = url sub;
      same-tab = true;
    }
    // removeAttrs args ["title" "sub" "icon"];
  monitor = title: sites: {
    type = "monitor";
    inherit title sites;
    cache = "5m";
  };
  bookmark = title: url: icon: {
    inherit title url icon;
    same-tab = true;
  };
in {
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
          type = "custom-api";
          title = "Home";
          title-url = "${url "ha"}/nixos-lovelace/home";
          cache = "1m";
          url = "http://127.0.0.1:8123/api/states";
          headers = {
            Authorization = "Bearer \${HA_TOKEN}";
            Accept = "application/json";
          };
          template = templates.home-status;
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
                (bookmark "Gmail" "https://mail.google.com" "si:gmail")
                (bookmark "Reddit" "https://old.reddit.com" "si:reddit")
                (bookmark "Github" "https://github.com" "si:github")
              ];
            }
            {
              title = "NixOS";
              links = [
                (bookmark "NixOS Search" "https://search.nixos.org" "si:nixos")
                (bookmark "Home-manager Search" "https://home-manager-options.extranix.com" "mdi:home")
                (bookmark "Noogle" "https://noogle.dev" "mdi:text-search")
              ];
            }
            {
              title = "Streaming";
              links = [
                (bookmark "YouTube" "https://youtube.com" "si:youtube")
                (bookmark "Twitch" "https://twitch.tv" "si:twitch")
                (bookmark "DR TV" "https://dr.dk/tv" "mdi:television")
              ];
            }
          ];
        }
        {
          type = "split-column";
          widgets = [
            {
              type = "custom-api";
              title = "Downloads";
              title-url = url "sabnzbd";
              cache = "1m";
              url = "http://127.0.0.1:8080/api";
              parameters = {
                mode = "queue";
                output = "json";
                apikey = "\${SABNZBD_API_KEY}";
              };
              template = templates.sabnzbd-queue;
            }
            {
              type = "custom-api";
              title = "Coming up";
              title-url = "${url "sonarr"}/calendar";
              cache = "30m";
              options = {
                sonarr-url = url "sonarr";
                radarr-url = url "radarr";
              };
              template = templates.coming-up;
            }
          ];
        }
        {
          type = "custom-api";
          title = "Recently added";
          title-url = url "jellyfin";
          cache = "30m";
          url = "http://127.0.0.1:8096/Users";
          headers = {
            Authorization = "MediaBrowser Token=\"\${JELLYFIN_API_KEY}\"";
            Accept = "application/json";
          };
          options.jellyfin-url = url "jellyfin";
          template = templates.recently-added;
        }
        {
          type = "group";
          widgets = [
            {
              type = "hacker-news";
              collapse-after = 10;
              limit = 30;
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
        {
          type = "split-column";
          widgets = [
            (monitor "Media" [
              (site {
                title = "Jellyfin";
                sub = "jellyfin";
                icon = "sh:jellyfin";
              })
              (site {
                title = "Navidrome";
                sub = "navidrome";
                icon = "sh:navidrome";
              })
              (site {
                title = "Audiobookshelf";
                sub = "audiobookshelf";
                icon = "sh:audiobookshelf";
              })
              (site {
                title = "Immich";
                sub = "immich";
                icon = "sh:immich";
              })
              (site {
                title = "Grimmory";
                sub = "grimmory";
                icon = "sh:booklore";
              })
              (site {
                title = "RomM";
                sub = "romm";
                icon = "sh:romm";
              })
              (site {
                title = "Shelfmark";
                sub = "shelfmark";
                icon = "sh:calibre-web-automated-book-downloader";
              })
              (site {
                title = "Runite";
                sub = "runite";
                icon = "mdi:podcast";
              })
            ])
            (monitor "Arr" [
              (site {
                title = "Sonarr";
                sub = "sonarr";
                icon = "sh:sonarr";
              })
              (site {
                title = "Radarr";
                sub = "radarr";
                icon = "sh:radarr";
              })
              (site {
                title = "Lidarr";
                sub = "lidarr";
                icon = "sh:lidarr";
              })
              (site {
                title = "Bazarr";
                sub = "bazarr";
                icon = "sh:bazarr";
              })
              (site {
                title = "Prowlarr";
                sub = "prowlarr";
                icon = "sh:prowlarr";
              })
              (site {
                title = "SABnzbd";
                sub = "sabnzbd";
                icon = "sh:sabnzbd";
              })
              (site {
                title = "qBittorrent";
                sub = "qbittorrent";
                icon = "sh:qbittorrent";
              })
            ])
            (monitor "Infra" [
              (site {
                title = "Home Assistant";
                sub = "ha";
                icon = "sh:home-assistant";
              })
              (site {
                title = "Zigbee2MQTT";
                sub = "zigbee";
                icon = "sh:zigbee2mqtt";
              })
              (site {
                title = "Nextcloud";
                sub = "nextcloud";
                icon = "sh:nextcloud";
              })
              (site {
                title = "Vaultwarden";
                sub = "bitwarden";
                icon = "sh:vaultwarden";
              })
              (site {
                title = "Attic";
                sub = "attic";
                icon = "sh:nix";
                alt-status-codes = [404];
              })
              (site {
                title = "Zitadel";
                sub = "sso";
                icon = "sh:zitadel";
              })
              (site {
                title = "Beszel";
                sub = "beszel";
                icon = "sh:beszel";
              })
              {
                title = "Grafana";
                url = "https://fireproof.grafana.net/";
                icon = "si:grafana";
                same-tab = true;
              }
            ])
            (monitor "External" [
              {
                title = "BM CMS";
                url = "https://cms.bmtomrermontage.dk/admin";
                icon = "sh:payload";
                same-tab = true;
              }
              {
                title = "BM Preview";
                url = "https://preview.bmtomrermontage.dk";
                icon = "mdi:web";
                same-tab = true;
              }
            ])
          ];
        }
      ];
    }
  ];
}
