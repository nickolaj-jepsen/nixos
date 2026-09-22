{templates}: let
  # One GraphQL call per widget; statusCheckRollup includes Actions check runs, which REST /status omits.
  prSearch = query: {
    type = "custom-api";
    cache = "10m";
    url = "https://api.github.com/graphql";
    headers.Authorization = "Bearer \${GITHUB_TOKEN}";
    body.query = ''
      {
        search(query: "${query}", type: ISSUE, first: 15) {
          nodes {
            ... on PullRequest {
              title url number isDraft mergeable createdAt updatedAt
              author { login avatarUrl(size: 32) }
              repository { nameWithOwner }
              reviewRequests { totalCount }
              commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
            }
          }
        }
      }
    '';
  };
  linearQuery = query: {
    type = "custom-api";
    cache = "5m";
    url = "https://api.linear.app/graphql";
    # Personal API keys go in raw; Linear rejects them with a Bearer prefix.
    headers.Authorization = "\${LINEAR_API_KEY}";
    body.query = query;
  };
in {
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
        (linearQuery ''
            {
              notifications(first: 50) {
                nodes { title subtitle inboxUrl createdAt readAt snoozedUntilAt actor { displayName } }
              }
            }
          ''
          // {
            title = "Inbox";
            title-url = "https://linear.app/inbox";
            cache = "2m";
            template = templates.linear-notifications;
          })
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
              title = "Communication";
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
            (linearQuery ''
                {
                  viewer {
                    assignedIssues(first: 25, orderBy: updatedAt, filter: {state: {type: {in: ["unstarted", "started"]}}}) {
                      nodes { identifier title url priority priorityLabel updatedAt state { name type color position } creator { displayName isMe } team { id key name } }
                    }
                  }
                  projects(first: 15, orderBy: updatedAt, filter: {
                    status: {type: {in: ["started", "planned"]}}
                    or: [{lead: {isMe: {eq: true}}}, {members: {some: {isMe: {eq: true}}}}]
                  }) {
                    nodes { name url progress health priority priorityLabel targetDate status { name type color } lead { displayName } }
                  }
                }
              ''
              // {
                title = "Linear";
                title-url = "https://linear.app";
                css-class = "linear-overview";
                template = templates.linear-overview;
              })
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
        (prSearch "is:pr is:open review-requested:@me"
          // {
            title = "PRs Awaiting Review";
            title-url = "https://github.com/pulls/review-requested";
            template = templates.prs-awaiting-review;
          })
        (prSearch "is:pr is:open author:@me sort:updated-desc"
          // {
            title = "My Pull Requests";
            title-url = "https://github.com/pulls";
            template = templates.my-pull-requests;
          })
      ];
    }
  ];
}
