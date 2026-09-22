{{ $items := .JSON.Array "data.search.nodes" }}
{{ if eq (len $items) 0 }}
  <p class="color-subdue" style="text-align: center;">No PRs awaiting review 🎉</p>
{{ else }}
  <ul class="list list-gap-10 collapsible-container" data-collapse-after="5">
    {{ range $i, $pr := $items }}
      {{ $url := $pr.String "url" }}
      {{ $login := $pr.String "author.login" }}
      {{ $repoPath := $pr.String "repository.nameWithOwner" }}
      {{ $state := $pr.String "commits.nodes.0.commit.statusCheckRollup.state" }}
      <li{{ if ge $i 5 }} class="collapsible-item" style="animation-delay: {{ mul (sub $i 5) 20 }}ms;"{{ end }}>
        <div style="display: flex; gap: 8px; align-items: flex-start;">
          <a href="https://github.com/{{ $login }}" style="flex-shrink: 0;">
            <img src="{{ $pr.String "author.avatarUrl" }}" alt="{{ $login }}" style="width: 24px; height: 24px; border-radius: 50%;" />
          </a>
          <div style="min-width: 0; flex: 1;">
            <a href="{{ $url }}" class="color-highlight" style="display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; line-height: 1.3;">{{ if $pr.Bool "isDraft" }}📝 {{ end }}{{ $pr.String "title" }}</a>
            <div style="font-size: 0.85em; margin-top: 2px;" class="color-subdue">
              <a href="https://github.com/{{ $login }}" class="color-primary" style="text-decoration: none;">{{ $login }}</a>
              · <a href="https://github.com/{{ $repoPath }}" class="color-subdue">{{ $repoPath }}</a>
              <a href="{{ $url }}" class="color-subdue">#{{ $pr.Int "number" }}</a>
              · <span {{ $pr.String "createdAt" | parseTime "rfc3339" | toRelativeTime }}></span>
              {{ if $state }}· <a href="{{ $url }}/checks" style="text-decoration: none;">{{ if eq $state "SUCCESS" }}✅{{ else if eq $state "FAILURE" }}❌{{ else if eq $state "ERROR" }}⚠️{{ else if eq $state "PENDING" }}🔄{{ else }}⏳{{ end }}</a>{{ end }}
              {{ if eq ($pr.String "mergeable") "CONFLICTING" }}· ⚠️ conflicts{{ end }}
            </div>
          </div>
        </div>
      </li>
    {{ end }}
  </ul>
{{ end }}
