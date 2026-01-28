{
  config,
  lib,
  pkgs,
  ...
}:
lib.mkIf config.fireproof.homelab.enable (let
  inherit (config.fireproof.theme) hsl;
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
                      url = "https://ha.nickolaj.com";
                      icon = "sh:home-assistant";
                      same-tab = true;
                    }
                    {
                      title = "Nextcloud";
                      url = "https://nextcloud.nickolaj.com";
                      icon = "sh:nextcloud";
                      same-tab = true;
                    }
                    {
                      title = "Zigbee2MQTT";
                      url = "https://zigbee.nickolaj.com";
                      icon = "sh:zigbee2mqtt";
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
                      title = "Navidrome";
                      url = "https://navidrome.nickolaj.com";
                      icon = "sh:navidrome";
                      same-tab = true;
                    }
                    {
                      title = "Mealie";
                      url = "https://mealie.nickolaj.com";
                      icon = "sh:mealie";
                      same-tab = true;
                    }
                    {
                      title = "Audiobookshelf";
                      url = "https://audiobookshelf.nickolaj.com";
                      icon = "sh:audiobookshelf";
                      same-tab = true;
                    }
                    {
                      title = "FreshRSS";
                      url = "https://freshrss.nickolaj.com";
                      icon = "sh:freshrss";
                      same-tab = true;
                    }
                    {
                      title = "Forgejo";
                      url = "https://forgejo.nickolaj.com";
                      icon = "sh:forgejo";
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
                      title = "Lidarr";
                      url = "https://lidarr.nickolaj.com";
                      icon = "sh:lidarr";
                      same-tab = true;
                    }
                    {
                      title = "SABnzbd";
                      url = "https://sabnzbd.nickolaj.com";
                      icon = "sh:sabnzbd";
                      same-tab = true;
                    }
                    {
                      title = "Prowlarr";
                      url = "https://prowlarr.nickolaj.com";
                      icon = "sh:prowlarr";
                      same-tab = true;
                    }
                    {
                      title = "qBittorrent";
                      url = "https://qbittorrent.nickolaj.com";
                      icon = "sh:qbittorrent";
                      same-tab = true;
                    }
                    {
                      title = "Zitadel";
                      url = "https://sso.nickolaj.com";
                      icon = "sh:zitadel";
                      same-tab = true;
                    }
                    {
                      title = "WireGuard";
                      url = "https://wg.nickolaj.com";
                      icon = "si:wireguard";
                      same-tab = true;
                    }
                    {
                      title = "Scrutiny";
                      url = "https://scrutiny.nickolaj.com";
                      icon = "sh:scrutiny";
                      same-tab = true;
                    }
                    {
                      title = "Grafana";
                      url = "https://fireproof.grafana.net/a/grafana-setupguide-app/home";
                      icon = "si:grafana";
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
                  type = "group";
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
            {
              size = "small";
              widgets = [
                {
                  type = "custom-api";
                  title = "Recent Repos";
                  title-url = "https://github.com";
                  cache = "10m";
                  url = "https://api.github.com/user/repos?sort=pushed&per_page=15&affiliation=owner,collaborator,organization_member";
                  headers = {
                    Authorization = "Bearer \${GITHUB_TOKEN}";
                    Accept = "application/vnd.github.v3+json";
                  };
                  template = ''
                    <ul class="list list-gap-10 collapsible-container" data-collapse-after="5">
                      {{ $items := .JSON.Array "" }}
                      {{ range $i, $repo := $items }}
                        {{ $repoPath := $repo.String "full_name" }}
                        <li{{ if ge $i 5 }} class="collapsible-item" style="animation-delay: {{ mul (sub $i 5) 20 }}ms;"{{ end }}>
                          <div style="display: flex; gap: 8px; align-items: flex-start;">
                            <a href="https://github.com/{{ $repo.String "owner.login" }}" style="flex-shrink: 0;">
                              <img src="{{ $repo.String "owner.avatar_url" }}&s=32" style="width: 20px; height: 20px; border-radius: 4px;" />
                            </a>
                            <div style="min-width: 0; flex: 1;">
                              <a href="{{ $repo.String "html_url" }}" class="color-highlight text-truncate block">{{ $repoPath }}</a>
                              <div style="font-size: 0.85em; margin-top: 2px;" class="color-subdue">
                                <span {{ $repo.String "pushed_at" | parseTime "rfc3339" | toRelativeTime }}></span>
                              </div>
                            </div>
                          </div>
                        </li>
                      {{ end }}
                    </ul>
                  '';
                }
                {
                  type = "custom-api";
                  title = "PRs Awaiting Review";
                  title-url = "https://github.com/pulls/review-requested";
                  cache = "10m";
                  url = "https://api.github.com/search/issues?q=is:pr+is:open+review-requested:@me&per_page=15";
                  headers = {
                    Authorization = "Bearer \${GITHUB_TOKEN}";
                    Accept = "application/vnd.github.v3+json";
                  };
                  template = ''
                    {{ $items := .JSON.Array "items" }}
                    {{ if eq (len $items) 0 }}
                      <p class="color-subdue" style="text-align: center;">No PRs awaiting review 🎉</p>
                    {{ else }}
                      <ul class="list list-gap-10 collapsible-container" data-collapse-after="5">
                        {{ range $i, $pr := $items }}
                          {{ $prDetails := newRequest ($pr.String "pull_request.url") | withHeader "Authorization" "Bearer ''${GITHUB_TOKEN}" | withHeader "Accept" "application/vnd.github.v3+json" | getResponse }}
                          {{ $headSha := $prDetails.JSON.String "head.sha" }}
                          {{ $repoPath := $pr.String "repository_url" | trimPrefix "https://api.github.com/repos/" }}
                          {{ $isDraft := $prDetails.JSON.Bool "draft" }}
                          {{ $mergeable := $prDetails.JSON.String "mergeable" }}
                          {{ $statusUrl := concat "https://api.github.com/repos/" $repoPath "/commits/" $headSha "/status" }}
                          {{ $status := newRequest $statusUrl | withHeader "Authorization" "Bearer ''${GITHUB_TOKEN}" | withHeader "Accept" "application/vnd.github.v3+json" | getResponse }}
                          {{ $state := $status.JSON.String "state" }}
                          {{ $statusCount := $status.JSON.Int "total_count" }}
                          <li{{ if ge $i 5 }} class="collapsible-item" style="animation-delay: {{ mul (sub $i 5) 20 }}ms;"{{ end }}>
                            <div style="display: flex; gap: 8px; align-items: flex-start;">
                              <a href="https://github.com/{{ $pr.String "user.login" }}" style="flex-shrink: 0;">
                                <img src="{{ $pr.String "user.avatar_url" }}&s=32" alt="{{ $pr.String "user.login" }}" style="width: 24px; height: 24px; border-radius: 50%;" />
                              </a>
                              <div style="min-width: 0; flex: 1;">
                                <a href="{{ $pr.String "html_url" }}" class="color-highlight" style="display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; line-height: 1.3;">{{ if $isDraft }}📝 {{ end }}{{ $pr.String "title" }}</a>
                                <div style="font-size: 0.85em; margin-top: 2px;" class="color-subdue">
                                  <a href="https://github.com/{{ $pr.String "user.login" }}" class="color-primary" style="text-decoration: none;">{{ $pr.String "user.login" }}</a>
                                  · <a href="https://github.com/{{ $repoPath }}" class="color-subdue">{{ $repoPath }}</a>
                                  <a href="{{ $pr.String "html_url" }}" class="color-subdue">#{{ $pr.Int "number" }}</a>
                                  · <span {{ $pr.String "created_at" | parseTime "rfc3339" | toRelativeTime }}></span>
                                  {{ if gt $statusCount 0 }}· <a href="{{ $pr.String "html_url" }}/checks" style="text-decoration: none;">{{ if eq $state "success" }}✅{{ else if eq $state "failure" }}❌{{ else if eq $state "error" }}⚠️{{ else if eq $state "pending" }}🔄{{ else }}⏳{{ end }}</a>{{ end }}
                                  {{ if eq $mergeable "false" }}· ⚠️ conflicts{{ end }}
                                </div>
                              </div>
                            </div>
                          </li>
                        {{ end }}
                      </ul>
                    {{ end }}
                  '';
                }
                {
                  type = "custom-api";
                  title = "My Pull Requests";
                  title-url = "https://github.com/pulls";
                  cache = "10m";
                  url = "https://api.github.com/search/issues?q=is:pr+is:open+author:@me&per_page=15&sort=updated";
                  headers = {
                    Authorization = "Bearer \${GITHUB_TOKEN}";
                    Accept = "application/vnd.github.v3+json";
                  };
                  template = ''
                    {{ $items := .JSON.Array "items" }}
                    {{ if eq (len $items) 0 }}
                      <p class="color-subdue" style="text-align: center;">No open pull requests</p>
                    {{ else }}
                      <ul class="list list-gap-10 collapsible-container" data-collapse-after="5">
                        {{ range $i, $pr := $items }}
                          {{ $prDetails := newRequest ($pr.String "pull_request.url") | withHeader "Authorization" "Bearer ''${GITHUB_TOKEN}" | withHeader "Accept" "application/vnd.github.v3+json" | getResponse }}
                          {{ $headSha := $prDetails.JSON.String "head.sha" }}
                          {{ $repoPath := $pr.String "repository_url" | trimPrefix "https://api.github.com/repos/" }}
                          {{ $isDraft := $prDetails.JSON.Bool "draft" }}
                          {{ $mergeable := $prDetails.JSON.String "mergeable" }}
                          {{ $statusUrl := concat "https://api.github.com/repos/" $repoPath "/commits/" $headSha "/status" }}
                          {{ $status := newRequest $statusUrl | withHeader "Authorization" "Bearer ''${GITHUB_TOKEN}" | withHeader "Accept" "application/vnd.github.v3+json" | getResponse }}
                          {{ $state := $status.JSON.String "state" }}
                          {{ $statusCount := $status.JSON.Int "total_count" }}
                          {{ $reviewers := $prDetails.JSON.Array "requested_reviewers" }}
                          {{ $reviewCount := len $reviewers }}
                          <li{{ if ge $i 5 }} class="collapsible-item" style="animation-delay: {{ mul (sub $i 5) 20 }}ms;"{{ end }}>
                            <div style="display: flex; gap: 8px; align-items: flex-start;">
                              {{ if gt $statusCount 0 }}<a href="{{ $pr.String "html_url" }}/checks" style="flex-shrink: 0; font-size: 1.2em; line-height: 1; text-decoration: none;">{{ if eq $state "success" }}✅{{ else if eq $state "failure" }}❌{{ else if eq $state "error" }}⚠️{{ else if eq $state "pending" }}🔄{{ else }}⏳{{ end }}</a>{{ end }}
                              <div style="min-width: 0; flex: 1;">
                                <a href="{{ $pr.String "html_url" }}" class="color-highlight" style="display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; line-height: 1.3;">{{ if $isDraft }}📝 {{ end }}{{ $pr.String "title" }}</a>
                                <div style="font-size: 0.85em; margin-top: 2px;" class="color-subdue">
                                  <a href="https://github.com/{{ $repoPath }}" class="color-subdue">{{ $repoPath }}</a>
                                  <a href="{{ $pr.String "html_url" }}" class="color-subdue">#{{ $pr.Int "number" }}</a>
                                  · <span {{ $pr.String "updated_at" | parseTime "rfc3339" | toRelativeTime }}></span>
                                  {{ if gt $reviewCount 0 }}· <a href="{{ $pr.String "html_url" }}" class="color-subdue">👀 {{ $reviewCount }}</a>{{ end }}
                                  {{ if eq $mergeable "false" }}· ⚠️ conflicts{{ end }}
                                </div>
                              </div>
                            </div>
                          </li>
                        {{ end }}
                      </ul>
                    {{ end }}
                  '';
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
