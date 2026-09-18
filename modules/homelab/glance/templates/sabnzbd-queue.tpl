{{ $slots := .JSON.Array "queue.slots" }}
{{ if eq (len $slots) 0 }}
  <p class="color-subdue">Queue is empty</p>
{{ else }}
  <ul class="list-horizontal-text margin-bottom-10">
    {{ if .JSON.Bool "queue.paused" }}<li class="color-negative">Paused</li>{{ end }}
    <li>{{ .JSON.String "queue.speed" }}B/s</li>
    <li>{{ .JSON.String "queue.sizeleft" }} left</li>
    <li>{{ .JSON.String "queue.timeleft" }}</li>
  </ul>
  <ul class="list list-gap-10 collapsible-container" data-collapse-after="5">
    {{ range $i, $s := $slots }}
      <li{{ if ge $i 5 }} class="collapsible-item"{{ end }}>
        <div class="size-h5 text-truncate" title="{{ $s.String "filename" }}">{{ $s.String "filename" }}</div>
        <div class="progress-bar margin-block-3"><div class="progress-value" style="--percent: {{ $s.String "percentage" }}"></div></div>
        <ul class="list-horizontal-text">
          <li>{{ $s.String "percentage" }}%</li>
          <li>{{ $s.String "sizeleft" }} left</li>
          <li>{{ $s.String "timeleft" }}</li>
          {{ if ne ($s.String "status") "Downloading" }}<li class="color-subdue">{{ $s.String "status" }}</li>{{ end }}
        </ul>
      </li>
    {{ end }}
  </ul>
{{ end }}
