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
