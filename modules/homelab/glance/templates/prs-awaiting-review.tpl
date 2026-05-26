{{ $items := .JSON.Array "items" }}
{{ if eq (len $items) 0 }}
  <p class="color-subdue" style="text-align: center;">No PRs awaiting review 🎉</p>
{{ else }}
  <ul class="list list-gap-10 collapsible-container" data-collapse-after="5">
    {{ range $i, $pr := $items }}
      {{ $prDetails := newRequest ($pr.String "pull_request.url") | withHeader "Authorization" "Bearer ${GITHUB_TOKEN}" | withHeader "Accept" "application/vnd.github.v3+json" | getResponse }}
      {{ $headSha := $prDetails.JSON.String "head.sha" }}
      {{ $repoPath := $pr.String "repository_url" | trimPrefix "https://api.github.com/repos/" }}
      {{ $isDraft := $prDetails.JSON.Bool "draft" }}
      {{ $mergeable := $prDetails.JSON.String "mergeable" }}
      {{ $statusUrl := concat "https://api.github.com/repos/" $repoPath "/commits/" $headSha "/status" }}
      {{ $status := newRequest $statusUrl | withHeader "Authorization" "Bearer ${GITHUB_TOKEN}" | withHeader "Accept" "application/vnd.github.v3+json" | getResponse }}
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
