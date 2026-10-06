{{ $rows := .JSON.Array "rows" }}
{{ $bad := .JSON.Int "bad" }}
{{ $warn := .JSON.Int "warn" }}
<div class="storage-status">
  <div class="storage-summary {{ if gt $bad 0 }}color-negative{{ else if gt $warn 0 }}storage-text-warn{{ else }}color-positive{{ end }}">
    {{ if gt $bad 0 }}{{ $bad }} problem{{ if gt $bad 1 }}s{{ end }}{{ if gt $warn 0 }}, {{ $warn }} warning{{ if gt $warn 1 }}s{{ end }}{{ end }}
    {{ else if gt $warn 0 }}{{ $warn }} warning{{ if gt $warn 1 }}s{{ end }}
    {{ else }}All healthy{{ end }}
    <span class="color-subdue"> · checked <span {{ .JSON.String "updated" | parseTime "unix" | toRelativeTime }}></span> ago</span>
  </div>
  {{ range $g := unique "group" $rows }}
    {{ $group := $g.String "group" }}
    <div class="size-h6 color-subdue storage-group">{{ $group }}</div>
    <ul class="list list-gap-4">
      {{ range $rows }}{{ if eq (.String "group") $group }}
        <li class="storage-row">
          <span class="storage-dot storage-{{ .String "status" }}"></span>
          <div class="storage-text">
            <div class="color-highlight text-truncate">{{ .String "name" }}</div>
            <div class="size-h6 color-subdue text-truncate">{{ .String "detail" }}{{ if .Exists "time" }} · <span {{ .String "time" | parseTime "unix" | toRelativeTime }}></span> ago{{ end }}</div>
          </div>
        </li>
      {{ end }}{{ end }}
    </ul>
  {{ end }}
</div>
