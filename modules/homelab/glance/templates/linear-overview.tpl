{{ $items := .JSON.Array "data.viewer.assignedIssues.nodes" }}
{{ $projects := .JSON.Array "data.projects.nodes" }}
{{/* Filter chips are CSS-only radios (glance won't run template scripts); chip N hides issues and groups without t-N. */}}
{{ $teams := unique "team.id" $items }}
<div class="linear-overview-grid">
  <div class="widget-content-frame linear-overview-box linear-issues">
    <div class="linear-issues-header">
      <a href="https://linear.app/my-issues" class="size-h4 color-highlight">Issues · {{ len $items }}</a>
      {{ if gt (len $teams) 1 }}
        <div class="linear-filter">
          {{/* Clear sits first: chips are right-aligned, so it appears without shifting them. */}}
          <label class="linear-filter-clear" title="Clear filter"><input type="radio" name="linear-team" value="all" checked>×</label>
          {{ range $i, $team := $teams }}
            {{ $count := 0 }}
            {{ range $items }}{{ if eq (.String "team.id") ($team.String "team.id") }}{{ $count = add $count 1 }}{{ end }}{{ end }}
            <label title="{{ $team.String "team.name" }}"><input type="radio" name="linear-team" id="linear-tf-{{ $i }}">{{ $team.String "team.key" }} <span>{{ $count }}</span></label>
          {{ end }}
        </div>
        <style>
          {{ range $i, $team := $teams }}
            .linear-issues:has(#linear-tf-{{ $i }}:checked) .linear-group:not(.t-{{ $i }}),
            .linear-issues:has(#linear-tf-{{ $i }}:checked) li:not(.t-{{ $i }}) { display: none; }
          {{ end }}
        </style>
      {{ end }}
    </div>
    {{ if eq (len $items) 0 }}
      <p class="color-subdue">No open issues</p>
    {{ end }}
    <div class="linear-groups">
    {{/* Linear lists states by descending position: In Review, In Progress, Todo. */}}
    {{ range $g, $group := sortByFloat "state.position" "desc" (unique "state.name" $items) }}
      {{ $name := $group.String "state.name" }}
      {{ $color := $group.String "state.color" }}
      <div class="linear-group{{ range $i, $team := $teams }}{{ range $items }}{{ if and (eq (.String "state.name") $name) (eq (.String "team.id") ($team.String "team.id")) }} t-{{ $i }}{{ end }}{{ end }}{{ end }}">
        <div class="size-h6 color-subdue" style="text-transform: uppercase; letter-spacing: 0.05em; margin-bottom: 8px;">{{ $name }}</div>
        <ul class="list list-gap-10 collapsible-container" data-collapse-after="5">
          {{/* Priority order 1..4 then 0 (none); sortByInt is unstable and would scramble the updatedAt order. */}}
          {{ range $k := 5 }}
            {{ $p := mod (add $k 1) 5 }}
            {{ range $issue := $items }}
              {{ if and (eq ($issue.String "state.name") $name) (eq ($issue.Int "priority") $p) }}
                {{ $url := $issue.String "url" }}
                {{ $ti := 0 }}
                {{ range $i, $team := $teams }}{{ if eq ($team.String "team.id") ($issue.String "team.id") }}{{ $ti = $i }}{{ end }}{{ end }}
                <li class="t-{{ $ti }}">
                  <div style="border-left: 3px solid {{ $color }}; padding-left: 8px; display: flex; gap: 8px; align-items: flex-start;">
                    {{ template "priority-icon" $issue }}
                    <div style="min-width: 0; flex: 1;">
                      <a href="{{ $url }}" class="color-highlight" style="display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; line-height: 1.3;">{{ $issue.String "title" }}</a>
                      <div style="font-size: 0.85em; margin-top: 2px;" class="color-subdue">
                        <a href="{{ $url }}" class="color-subdue">{{ $issue.String "identifier" }}</a>
                        {{ with $issue.String "creator.displayName" }}{{ if not ($issue.Bool "creator.isMe") }}· by {{ . }}{{ end }}{{ end }}
                        · <span {{ $issue.String "updatedAt" | parseTime "rfc3339" | toRelativeTime }}></span>
                      </div>
                    </div>
                  </div>
                </li>
              {{ end }}
            {{ end }}
          {{ end }}
        </ul>
      </div>
    {{ end }}
    </div>
  </div>

  <div class="widget-content-frame linear-overview-box">
    <a href="https://linear.app/projects" class="size-h4 color-highlight" style="display: block; margin-bottom: 10px;">Projects · {{ len $projects }}</a>
    {{ if eq (len $projects) 0 }}
      <p class="color-subdue">No active projects</p>
    {{ end }}
    <ul class="list list-gap-14 collapsible-container" data-collapse-after="6">
      {{ $j := 0 }}
      {{/* Started before planned; within each, the API's updatedAt order. */}}
      {{ range $k := 2 }}
        {{ $type := "started" }}{{ if eq $k 1 }}{{ $type = "planned" }}{{ end }}
        {{ range $project := $projects }}
          {{ if eq ($project.String "status.type") $type }}
            {{ $url := $project.String "url" }}
            {{ $health := $project.String "health" }}
            {{ $color := $project.String "status.color" }}
            {{ $progress := mul ($project.Float "progress") 100 | toInt }}
            <li{{ if ge $j 6 }} class="collapsible-item" style="animation-delay: {{ mul (sub $j 6) 20 }}ms;"{{ end }}>
              <div style="display: flex; gap: 8px; align-items: flex-start;">
                {{ template "priority-icon" $project }}
                <a href="{{ $url }}" class="color-highlight" style="flex: 1; min-width: 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis;">{{ $project.String "name" }}</a>
                {{ if eq $health "onTrack" }}<span class="color-positive linear-health">On track</span>
                {{ else if eq $health "atRisk" }}<span class="linear-health" style="color: #f2c94c;">At risk</span>
                {{ else if eq $health "offTrack" }}<span class="color-negative linear-health">Off track</span>
                {{ else }}<span class="color-subdue linear-health linear-health-none">No updates</span>{{ end }}
              </div>
              <div style="display: flex; gap: 8px; align-items: center; margin-top: 5px;">
                <div style="flex: 1; height: 4px; border-radius: 2px; background: var(--color-widget-background-highlight); overflow: hidden;">
                  <div style="height: 100%; width: {{ $progress }}%; background: {{ $color }};"></div>
                </div>
                <span class="color-subdue" style="font-size: 0.85em; min-width: 3ch; text-align: right;">{{ $progress }}%</span>
              </div>
              <div style="font-size: 0.85em; margin-top: 3px;" class="color-subdue">
                {{ $project.String "status.name" }}
                {{ with $project.String "targetDate" }}
                  {{ $target := parseTime "dateonly" . }}
                  · <span{{ if $target.Before (startOfDay now) }} class="color-negative"{{ end }}>Due {{ formatTime "Jan 2" $target }}</span>
                {{ end }}
                {{ with $project.String "lead.displayName" }}· {{ . }}{{ end }}
              </div>
            </li>
            {{ $j = add $j 1 }}
          {{ end }}
        {{ end }}
      {{ end }}
    </ul>
  </div>
</div>

{{/* Linear-style priority glyph for any node with priority + priorityLabel. */}}
{{ define "priority-icon" }}
  {{ $p := .Int "priority" }}
  <svg viewBox="0 0 16 16" width="14" height="14" style="flex-shrink: 0; margin-top: 0.2em;" aria-label="{{ .String "priorityLabel" }}"><title>{{ .String "priorityLabel" }}</title>
    {{ if eq $p 1 }}
      <rect x="1" y="1" width="14" height="14" rx="3" fill="var(--color-negative)"/><rect x="7" y="3.5" width="2" height="6" rx="1" fill="var(--color-widget-background)"/><rect x="7" y="10.75" width="2" height="2" rx="1" fill="var(--color-widget-background)"/>
    {{ else if eq $p 0 }}
      <g fill="currentColor" opacity="0.4"><rect x="1.5" y="7.25" width="3" height="1.5" rx="0.75"/><rect x="6.5" y="7.25" width="3" height="1.5" rx="0.75"/><rect x="11.5" y="7.25" width="3" height="1.5" rx="0.75"/></g>
    {{ else }}
      <g fill="currentColor"><rect x="1.5" y="8" width="3" height="6" rx="1"/><rect x="6.5" y="5" width="3" height="9" rx="1"{{ if gt $p 3 }} opacity="0.3"{{ end }}/><rect x="11.5" y="2" width="3" height="12" rx="1"{{ if gt $p 2 }} opacity="0.3"{{ end }}/></g>
    {{ end }}
  </svg>
{{ end }}
