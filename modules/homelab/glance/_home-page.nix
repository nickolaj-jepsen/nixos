{
  cfg,
  services,
}: {
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
          # SSO-gated sites need a loopback check-url; the public URL only reaches the Zitadel login.
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
              check-url = "http://127.0.0.1:${toString services.zigbee2mqtt.settings.frontend.port}";
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
              check-url = "http://127.0.0.1:${toString services.navidrome.settings.Port}/ping";
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
              title = "Grimmory";
              url = "https://grimmory.${cfg.domain}";
              icon = "sh:booklore";
              same-tab = true;
            }
            {
              title = "RomM";
              url = "https://romm.${cfg.domain}";
              icon = "sh:romm";
              same-tab = true;
            }
            {
              title = "Shelfmark";
              url = "https://shelfmark.${cfg.domain}";
              check-url = "http://127.0.0.1:${toString services.shelfmark.environment.FLASK_PORT}";
              icon = "sh:calibre-web-automated-book-downloader";
              same-tab = true;
            }
            {
              title = "Sonarr";
              url = "https://sonarr.${cfg.domain}";
              check-url = "http://127.0.0.1:${toString services.sonarr.settings.server.port}/ping";
              icon = "sh:sonarr";
              same-tab = true;
            }
            {
              title = "Radarr";
              url = "https://radarr.${cfg.domain}";
              check-url = "http://127.0.0.1:${toString services.radarr.settings.server.port}/ping";
              icon = "sh:radarr";
              same-tab = true;
            }
            {
              title = "Lidarr";
              url = "https://lidarr.${cfg.domain}";
              check-url = "http://127.0.0.1:${toString services.lidarr.settings.server.port}/ping";
              icon = "sh:lidarr";
              same-tab = true;
            }
            {
              title = "SABnzbd";
              url = "https://sabnzbd.${cfg.domain}";
              check-url = "http://127.0.0.1:${toString services.sabnzbd.settings.misc.port}";
              icon = "sh:sabnzbd";
              same-tab = true;
            }
            {
              title = "Prowlarr";
              url = "https://prowlarr.${cfg.domain}";
              check-url = "http://127.0.0.1:${toString services.prowlarr.settings.server.port}/ping";
              icon = "sh:prowlarr";
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
              title = "BM CMS";
              url = "https://cms.bmtomrermontage.dk/admin";
              icon = "sh:payload";
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
          ];
        }
      ];
    }
  ];
}
