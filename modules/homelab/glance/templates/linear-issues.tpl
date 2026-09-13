{{ define "issue" }}
  <a class="size-h4 color-highlight block text-truncate" href="{{ .String "url" }}">{{ .String "title" }}</a>
  <ul class="list-horizontal-text">
    <li>{{ .String "identifier" }}</li>
    {{ if .Exists "project.name" }}<li class="text-truncate">{{ .String "project.name" }}</li>{{ end }}
    {{ $p := .Int "priority" }}{{ if and (gt $p 0) (le $p 2) }}<li class="color-negative">{{ .String "priorityLabel" }}</li>{{ end }}
    <li {{ .String "updatedAt" | parseTime "rfc3339" | toRelativeTime }}></li>
  </ul>
{{ end }}
{{ $started := .JSON.Array `data.viewer.assignedIssues.nodes.#(state.type=="started")#` }}
{{ $todo := .JSON.Array `data.viewer.assignedIssues.nodes.#(state.type=="unstarted")#` }}
{{ $backlog := .JSON.Array `data.viewer.assignedIssues.nodes.#(state.type=="backlog")#` }}
{{ if and (eq (len $started) 0) (eq (len $todo) 0) (eq (len $backlog) 0) }}
  <p class="color-subdue">No open issues 🎉</p>
{{ else }}
  {{ $i := 0 }}
  <ul class="list list-gap-10 collapsible-container" data-collapse-after="10">
    {{ if gt (len $started) 0 }}<li class="size-h6 color-subdue uppercase">In progress</li>{{ end }}
    {{ range $started }}<li{{ if ge $i 10 }} class="collapsible-item"{{ end }}>{{ template "issue" . }}</li>{{ $i = add $i 1 }}{{ end }}
    {{ if gt (len $todo) 0 }}<li class="size-h6 color-subdue uppercase">Todo</li>{{ end }}
    {{ range $todo }}<li{{ if ge $i 10 }} class="collapsible-item"{{ end }}>{{ template "issue" . }}</li>{{ $i = add $i 1 }}{{ end }}
    {{ if gt (len $backlog) 0 }}<li class="size-h6 color-subdue uppercase">Backlog</li>{{ end }}
    {{ range $backlog }}<li{{ if ge $i 10 }} class="collapsible-item"{{ end }}>{{ template "issue" . }}</li>{{ $i = add $i 1 }}{{ end }}
  </ul>
{{ end }}
