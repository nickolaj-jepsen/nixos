{{/* Latest is per-user; the API key has no user, so borrow the first admin's view (sees every library). */}}
{{ $uid := .JSON.String `#(Policy.IsAdministrator==true).Id` }}
{{ $jf := .Options.StringOr "jellyfin-url" "" }}
{{ $latest := newRequest (concat "http://127.0.0.1:8096/Users/" $uid "/Items/Latest") | withParameter "limit" "10" | withParameter "fields" "DateCreated" | withHeader "Authorization" "MediaBrowser Token=\"${JELLYFIN_API_KEY}\"" | getResponse }}
{{ if ne $latest.Response.StatusCode 200 }}
  <p class="color-negative">Jellyfin returned {{ $latest.Response.Status }}</p>
{{ else }}
  {{ $items := $latest.JSON.Array "" }}
  {{ if eq (len $items) 0 }}
    <p class="color-subdue">Nothing added recently</p>
  {{ else }}
    <div class="fp-posters">
      {{ range $items }}
        {{ $id := .String "Id" }}{{ $tag := .String "ImageTags.Primary" }}{{ $name := .String "Name" }}
        {{ if eq (.String "Type") "Episode" }}{{ $id = .String "SeriesId" }}{{ $tag = .String "SeriesPrimaryImageTag" }}{{ $name = .String "SeriesName" }}{{ end }}
        <a class="fp-poster" href="{{ $jf }}/web/#/details?id={{ $id }}" title="{{ $name }}">
          <img src="{{ $jf }}/Items/{{ $id }}/Images/Primary?fillWidth=200&fillHeight=300&quality=90&tag={{ $tag }}" alt="{{ $name }}" loading="lazy">
          <div class="size-h6 color-highlight text-truncate">{{ $name }}</div>
          <div class="size-h6 color-subdue" {{ .String "DateCreated" | parseTime "rfc3339" | toRelativeTime }}></div>
        </a>
      {{ end }}
    </div>
  {{ end }}
{{ end }}
