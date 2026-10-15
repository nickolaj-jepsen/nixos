{
  cfg,
  lib,
  services,
  templates,
}: let
  statusPort = (builtins.head services.nginx.virtualHosts."status.localhost".listen).port;

  groupOrder = ["home" "media" "downloads" "infra"];
  toSite = m:
    {
      inherit (m) title url icon;
      same-tab = true;
    }
    // lib.optionalAttrs (m.checkUrl != null) {check-url = m.checkUrl;}
    // lib.optionalAttrs (m.altStatusCodes != []) {alt-status-codes = m.altStatusCodes;};
  monitorSites = lib.concatMap (group:
    map toSite (lib.sort (a: b: lib.toLower a.title < lib.toLower b.title)
      (lib.filter (m: m.group == group) (lib.attrValues cfg.dashboard.monitors))))
  groupOrder;
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
          type = "server-stats";
          servers = [
            {
              type = "local";
              name = "Home Server";
            }
          ];
        }
        {
          type = "custom-api";
          title = "Storage";
          title-url = "https://fireproof.grafana.net/alerting/list";
          cache = "1m";
          # Written by storage-status.service.
          url = "http://127.0.0.1:${toString statusPort}/storage.json";
          template = templates.storage-status;
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
          sites = monitorSites;
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
