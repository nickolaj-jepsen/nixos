{{ $rows := .JSON.Array "rows" }}
<ul class="list list-gap-10 storage-status">
  {{ range .JSON.Array "groups" }}
    {{ $group := .String "name" }}
    <li>
      <div class="storage-row">
        <span class="storage-dot storage-{{ .String "status" }}"></span>
        <span class="color-highlight">{{ $group }}</span>
        <span class="color-subdue text-truncate">{{ .String "summary" }}{{ if .Exists "time" }} <span {{ .String "time" | parseTime "unix" | toRelativeTime }}></span> ago{{ end }}</span>
      </div>
      {{ range $rows }}{{ if and (eq (.String "group") $group) (or (eq (.String "status") "warn") (eq (.String "status") "bad")) }}
        <div class="storage-problem size-h6 storage-text-{{ .String "status" }}">{{ .String "name" }}: {{ .String "detail" }}</div>
      {{ end }}{{ end }}
    </li>
  {{ end }}
</ul>
{{/* The timer runs every 5 min; older data means the collector itself stopped. */}}
{{ if (.JSON.String "updated" | parseTime "unix").Before (offsetNow "-15m") }}
  <div class="size-h6 color-negative storage-stale">Stale: last checked <span {{ .JSON.String "updated" | parseTime "unix" | toRelativeTime }}></span> ago</div>
{{ end }}
