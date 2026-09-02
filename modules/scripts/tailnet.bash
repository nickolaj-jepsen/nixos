# Switch the single tailscaled between its two profiles. The personal profile is
# the one tagged tag:fireproof (enrolled by tailscaled-autoconnect); the work
# profile is the other one, added once per host with `tailscale login`. Only the
# active profile exposes its tags, so "the other profile" must be unambiguous.
#
#   tailnet          print the active profile: home | work | off
#   tailnet toggle   switch to the other profile
#   tailnet home     switch to the personal profile
#   tailnet work     switch to the work profile
#   tailnet link     disconnect (tailscale down) or reconnect the active profile
set -euo pipefail

TAG="tag:fireproof"

status_json() { tailscale status --json --peers=false 2>/dev/null || echo '{}'; }

current() {
  local json
  json=$(status_json)
  if [ "$(jq -r '.BackendState' <<<"$json")" != "Running" ]; then
    echo off
  elif jq -e --arg t "$TAG" '(.Self.Tags // []) | index($t)' <<<"$json" >/dev/null; then
    echo home
  else
    echo work
  fi
}

# IDs of every profile except the active one (its account carries a trailing "*").
other_ids() {
  tailscale switch --list 2>/dev/null | awk 'NR > 1 && $NF !~ /\*$/ {print $1}' || true
}

fail() {
  echo "tailnet: $*" >&2
  if [ -n "${WAYLAND_DISPLAY:-}" ]; then
    notify-send --app-name=tailnet "Tailnet" "$*"
  fi
  exit 1
}

switch_other() {
  local ids
  ids=$(other_ids)
  case "$(wc -w <<<"$ids")" in
    0) fail "no other profile — run 'tailscale login' while on the personal profile to add the work one" ;;
    1) tailscale switch "$ids" >/dev/null ;;
    *) fail "more than two profiles; pick one with 'tailscale switch' by hand" ;;
  esac
  current
}

# Plain `tailscale up` keeps the prefs the profile was brought up with (tags etc.).
link() {
  case "$(jq -r '.BackendState' <<<"$(status_json)")" in
    Running) tailscale down ;;
    Stopped) tailscale up ;;
    *) fail "not logged in; nothing to reconnect" ;;
  esac
  current
}

case "${1:-status}" in
  status) current ;;
  toggle) switch_other ;;
  link) link ;;
  home | work)
    now=$(current)
    if [ "$now" = off ]; then
      fail "tailscale is not running; use 'tailnet toggle'"
    elif [ "$now" = "$1" ]; then
      echo "$1"
    else
      switch_other
    fi
    ;;
  *)
    echo "usage: tailnet [status|toggle|home|work|link]" >&2
    exit 2
    ;;
esac
