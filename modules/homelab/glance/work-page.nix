{templates}: {
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
          template = templates.recent-repos;
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
          template = templates.prs-awaiting-review;
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
          template = templates.my-pull-requests;
        }
      ];
    }
  ];
}
