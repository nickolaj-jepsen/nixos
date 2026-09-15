{{ $start := now | startOfDay }}
{{ $end := offsetNow "192h" | startOfDay }}
{{ $from := $start | formatTime "DateOnly" }}
{{ $to := $end | formatTime "DateOnly" }}
{{ $sonarr := newRequest "http://127.0.0.1:8989/api/v3/calendar" | withParameter "start" $from | withParameter "end" $to | withParameter "includeSeries" "true" | withHeader "X-Api-Key" "${SONARR_API_KEY}" | getResponse }}
{{ $radarr := newRequest "http://127.0.0.1:7878/api/v3/calendar" | withParameter "start" $from | withParameter "end" $to | withHeader "X-Api-Key" "${RADARR_API_KEY}" | getResponse }}
{{ if ne $sonarr.Response.StatusCode 200 }}<p class="color-negative">Sonarr returned {{ $sonarr.Response.Status }}</p>{{ end }}
{{ if ne $radarr.Response.StatusCode 200 }}<p class="color-negative">Radarr returned {{ $radarr.Response.Status }}</p>{{ end }}
{{ $episodes := sortByTime "airDateUtc" "rfc3339" "asc" ($sonarr.JSON.Array "") }}
{{ $movies := $radarr.JSON.Array "" }}
{{ $sonarrUrl := .Options.StringOr "sonarr-url" "" }}
{{ $radarrUrl := .Options.StringOr "radarr-url" "" }}
{{ if and (eq (len $episodes) 0) (eq (len $movies) 0) }}
  <p class="color-subdue">Nothing due in the next 7 days</p>
{{ else }}
  <ul class="list list-gap-10 collapsible-container" data-collapse-after="8">
    {{ range $i, $e := $episodes }}
      <li{{ if ge $i 8 }} class="collapsible-item"{{ end }}>
        <a class="size-h4 color-highlight block text-truncate" href="{{ $sonarrUrl }}/series/{{ $e.String "series.titleSlug" }}">{{ $e.String "series.title" }}</a>
        <ul class="list-horizontal-text">
          <li>{{ printf "S%02dE%02d" ($e.Int "seasonNumber") ($e.Int "episodeNumber") }}</li>
          <li class="text-truncate">{{ $e.String "title" }}</li>
          <li {{ $e.String "airDateUtc" | parseTime "rfc3339" | toRelativeTime }}></li>
          {{ if $e.Bool "hasFile" }}<li class="color-positive">downloaded</li>{{ end }}
        </ul>
      </li>
    {{ end }}
    {{ range $i, $m := $movies }}
      {{/* Radarr returns a movie when any of its three dates falls in the window; show the first that does. */}}
      {{ $when := "" }}{{ $kind := "" }}
      {{ if $m.Exists "digitalRelease" }}{{ $d := $m.String "digitalRelease" | parseTime "rfc3339" }}{{ if and (not ($d.Before $start)) ($d.Before $end) }}{{ $when = $m.String "digitalRelease" }}{{ $kind = "digital" }}{{ end }}{{ end }}
      {{ if and (eq $when "") ($m.Exists "physicalRelease") }}{{ $d := $m.String "physicalRelease" | parseTime "rfc3339" }}{{ if and (not ($d.Before $start)) ($d.Before $end) }}{{ $when = $m.String "physicalRelease" }}{{ $kind = "disc" }}{{ end }}{{ end }}
      {{ if and (eq $when "") ($m.Exists "inCinemas") }}{{ $d := $m.String "inCinemas" | parseTime "rfc3339" }}{{ if and (not ($d.Before $start)) ($d.Before $end) }}{{ $when = $m.String "inCinemas" }}{{ $kind = "cinema" }}{{ end }}{{ end }}
      <li{{ if ge (add $i (len $episodes)) 8 }} class="collapsible-item"{{ end }}>
        <a class="size-h4 color-highlight block text-truncate" href="{{ $radarrUrl }}/movie/{{ $m.String "titleSlug" }}">{{ $m.String "title" }} ({{ $m.Int "year" }})</a>
        <ul class="list-horizontal-text">
          {{ if ne $kind "" }}<li>{{ $kind }}</li><li {{ $when | parseTime "rfc3339" | toRelativeTime }}></li>{{ end }}
          {{ if $m.Bool "hasFile" }}<li class="color-positive">downloaded</li>{{ end }}
        </ul>
      </li>
    {{ end }}
  </ul>
{{ end }}
