# Go template for the Home Assistant status widget, built from the same
# inventory as the HA dashboard (home-assistant/_devices.nix). The widget fetches
# /api/states once; every lookup below is a gjson query into that array.
{
  lib,
  dev,
  haUrl,
}: let
  state = e: ''(.JSON.String `#(entity_id=="${e}").state`)'';
  attr = e: a: ''(.JSON.String `#(entity_id=="${e}").attributes.${a}`)'';
  isOn = e: ''(eq ${state e} "on")'';
  # `and` short-circuits nothing in Go templates, so a missing entity yields "" and every branch stays quiet.
  notIn = e: values: ''(and ${lib.concatMapStringsSep " " (v: ''(ne ${state e} "${v}")'') (values ++ [""])})'';
  unknown = ["unknown" "unavailable"];

  # One counter per room: Go templates do not allow redeclaring a variable in the same scope.
  countOn = n: lights: lib.concatMapStrings (l: ''{{ if ${isOn (dev.light l)} }}{{ ${n} = add ${n} 1 }}{{ end }}'') lights;
  roomRow = key: room: let
    n = "$on_${key}";
  in ''
    {{ ${n} := 0 }}${countOn n room.lights}
    <li class="flex justify-between">
      <span>${room.name}</span>
      <span class="{{ if gt ${n} 0 }}color-primary{{ else }}color-subdue{{ end }}">{{ ${n} }}/${toString (lib.length room.lights)} on</span>
    </li>
  '';

  context = ''
    {{ if ${isOn dev.helpers.sleepMode} }}<li>Sleep mode</li>{{ end }}
    {{ if ${isOn dev.helpers.guestMode} }}<li>Guest mode</li>{{ end }}
    {{ if (eq ${state dev.person} "not_home") }}<li>Away{{ if ${isOn dev.helpers.awaySimulation} }} · simulation running{{ end }}</li>{{ end }}
    {{ if (eq ${state dev.zwift.online} "True") }}<li>Riding · {{ ${state dev.zwift.power} }}&nbsp;W · {{ ${state dev.zwift.heartRate} }}&nbsp;bpm</li>{{ end }}
    {{ $shield := ${state dev.jellyfinShield} }}
    {{ if or (eq $shield "playing") (eq $shield "paused") }}
      {{ $title := ${attr dev.jellyfinShield "media_series_title"} }}{{ if eq $title "" }}{{ $title = ${attr dev.jellyfinShield "media_title"} }}{{ end }}
      <li class="text-truncate">{{ $title }} on the Shield{{ if eq $shield "paused" }} (paused){{ end }}</li>
    {{ end }}
    {{ if (eq ${state dev.spotify} "playing") }}<li class="text-truncate">{{ ${attr dev.spotify "media_title"} }} · {{ ${attr dev.spotify "media_artist"} }}</li>{{ end }}
    {{ if ${notIn dev.saa.nextAlarm unknown} }}<li>Alarm <span {{ ${state dev.saa.nextAlarm} | parseTime "rfc3339" | toRelativeTime }}></span>{{ if ${notIn dev.saa.alarmLabel unknown} }} · {{ ${state dev.saa.alarmLabel} }}{{ end }}</li>{{ end }}
    {{ if ${notIn dev.printer.status (unknown ++ ["idle" "offline" "finish" "failed"])} }}<li class="text-truncate">Printing {{ ${state dev.printer.taskName} }} · {{ ${state dev.printer.progress} }}%</li>{{ end }}
  '';
in ''
  {{ if ne .Response.StatusCode 200 }}
    <p class="color-negative">Home Assistant returned {{ .Response.Status }}</p>
  {{ else }}
    <ul class="list list-gap-4 fp-context color-highlight">
      ${context}
    </ul>
    <ul class="list list-gap-4">
      ${lib.concatStrings (lib.mapAttrsToList roomRow dev.rooms)}
    </ul>
    <a class="size-h6 color-subdue block margin-top-10" href="${haUrl}/nixos-lovelace/home">Open Home Assistant</a>
  {{ end }}
''
