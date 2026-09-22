{{/* The API can't filter on readAt, so unread and unsnoozed are picked out here. */}}
{{ $unread := 0 }}
<ul class="list list-gap-10 collapsible-container" data-collapse-after="5">
  {{ range .JSON.Array "data.notifications.nodes" }}
    {{ $snoozed := false }}
    {{ with .String "snoozedUntilAt" }}{{ $snoozed = (parseTime "rfc3339" .).After now }}{{ end }}
    {{ if and (eq (.String "readAt") "") (not $snoozed) }}
      <li{{ if ge $unread 5 }} class="collapsible-item" style="animation-delay: {{ mul (sub $unread 5) 20 }}ms;"{{ end }}>
        <a href="{{ .String "inboxUrl" }}" class="color-highlight" style="display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; line-height: 1.3;">{{ .String "title" }}</a>
        <div style="font-size: 0.85em; margin-top: 2px; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden;" class="color-subdue">
          {{ with .String "actor.displayName" }}{{ . }} · {{ end }}<span {{ .String "createdAt" | parseTime "rfc3339" | toRelativeTime }}></span>
          {{ with .String "subtitle" }}<br>{{ . }}{{ end }}
        </div>
      </li>
      {{ $unread = add $unread 1 }}
    {{ end }}
  {{ end }}
</ul>
{{ if eq $unread 0 }}
  <p class="color-subdue" style="text-align: center;">Inbox zero</p>
{{ end }}
