{cfg}: {
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
                  url = "https://old.reddit.com";
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
                  icon = "mdi:home";
                  same-tab = true;
                }
                {
                  title = "Noogle";
                  url = "https://noogle.dev";
                  icon = "mdi:text-search";
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
                  title = "Twitch";
                  url = "https://twitch.tv";
                  icon = "si:twitch";
                  same-tab = true;
                }
                {
                  title = "DR TV";
                  url = "https://dr.dk/tv";
                  icon = "mdi:television";
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
              url = "https://ha.${cfg.domain}";
              icon = "sh:home-assistant";
              same-tab = true;
            }
            {
              title = "Nextcloud";
              url = "https://nextcloud.${cfg.domain}";
              icon = "sh:nextcloud";
              same-tab = true;
            }
            {
              title = "Zigbee2MQTT";
              url = "https://zigbee.${cfg.domain}";
              icon = "sh:zigbee2mqtt";
              same-tab = true;
            }
            {
              title = "Plex";
              url = "https://plex.${cfg.domain}";
              icon = "sh:plex";
              same-tab = true;
              alt-status-codes = [401];
            }
            {
              title = "Jellyfin";
              url = "https://jellyfin.${cfg.domain}";
              icon = "sh:jellyfin";
              same-tab = true;
            }
            {
              title = "Navidrome";
              url = "https://navidrome.${cfg.domain}";
              icon = "sh:navidrome";
              same-tab = true;
            }
            {
              title = "Audiobookshelf";
              url = "https://audiobookshelf.${cfg.domain}";
              icon = "sh:audiobookshelf";
              same-tab = true;
            }
            {
              title = "Kavita";
              url = "https://kavita.${cfg.domain}";
              icon = "sh:kavita";
              same-tab = true;
            }
            {
              title = "Shelfmark";
              url = "https://shelfmark.${cfg.domain}";
              icon = "sh:calibre-web-automated-book-downloader";
              same-tab = true;
            }
            {
              title = "Sonarr";
              url = "https://sonarr.${cfg.domain}";
              icon = "sh:sonarr";
              same-tab = true;
            }
            {
              title = "Radarr";
              url = "https://radarr.${cfg.domain}";
              icon = "sh:radarr";
              same-tab = true;
            }
            {
              title = "Lidarr";
              url = "https://lidarr.${cfg.domain}";
              icon = "sh:lidarr";
              same-tab = true;
            }
            {
              title = "SABnzbd";
              url = "https://sabnzbd.${cfg.domain}";
              icon = "sh:sabnzbd";
              same-tab = true;
            }
            {
              title = "Prowlarr";
              url = "https://prowlarr.${cfg.domain}";
              icon = "sh:prowlarr";
              same-tab = true;
            }
            {
              title = "qBittorrent";
              url = "https://qbittorrent.${cfg.domain}";
              icon = "sh:qbittorrent";
              same-tab = true;
            }
            {
              title = "Attic";
              url = "https://attic.${cfg.domain}";
              icon = "sh:nix";
              same-tab = true;
              alt-status-codes = [404];
            }
            {
              title = "Zitadel";
              url = "https://sso.${cfg.domain}";
              icon = "sh:zitadel";
              same-tab = true;
            }
            {
              title = "Grafana";
              url = "https://fireproof.grafana.net/a/grafana-setupguide-app/home";
              icon = "si:grafana";
              same-tab = true;
            }
            {
              title = "Beszel";
              url = "https://beszel.${cfg.domain}";
              icon = "sh:beszel";
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
      ];
    }
  ];
}
