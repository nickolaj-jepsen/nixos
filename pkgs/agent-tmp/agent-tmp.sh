#!/usr/bin/env bash
# The agent temp janitor. Coding agents get TMPDIR under one root the sweeper
# owns, named after the pid of the agent process, so a directory whose pid is
# gone can be proven dead instead of guessed at from its mtime.
#
#   dir        print (and create) <pid>'s temp dir; the agent wrappers pass their own $$
#   state      refresh the cached numbers the status lines read
#   status     report what is here and what a sweep would take
#   sweep      delete what the rules free (the timer's job)
#   warn       Claude Code PreToolUse hook: JSON handing the model one line under pressure
#   warnline   the same line as plain text, for pi's tool_result hook
#   statusline the footer segment, from the cached state
#
# Nothing here needs root: every path is owned by the user running agents.
set -euo pipefail

ROOT=${AGENT_TMP_ROOT:-/tmp/agent}
# A budget, not a cap: it is what the sweeper defends by evicting dead sessions.
BUDGET_GIB=${AGENT_TMP_BUDGET_GIB:-16}
MAX_AGE_DAYS=${AGENT_TMP_MAX_AGE_DAYS:-3}
FREE_FLOOR_PCT=${AGENT_TMP_FREE_FLOOR_PCT:-10}
WARN_FREE_GIB=${AGENT_TMP_WARN_FREE_GIB:-10}
# One line per ten minutes is enough to be heard without becoming wallpaper.
WARN_EVERY_SECONDS=${AGENT_TMP_WARN_EVERY_SECONDS:-600}
# A legacy dir the session registry has never heard of is only idle-guessed; an
# hour without a write is longer than a live session goes without touching it.
LEGACY_IDLE_SECONDS=3600
# The status lines refresh their cached numbers no more often than this.
STATE_TTL_SECONDS=60
# A kept dir below this is not worth a line in the report.
REPORT_KEEP_BYTES=$((64 * 1024 * 1024))
# Nor is a freed one: a report is about what is holding the space, not a census.
REPORT_FREE_BYTES=$((1024 * 1024))

BUDGET_BYTES=$((BUDGET_GIB * 1024 * 1024 * 1024))
MAX_AGE_SECONDS=$((MAX_AGE_DAYS * 86400))
WARN_FREE_BYTES=$((WARN_FREE_GIB * 1024 * 1024 * 1024))
LEGACY_ROOT=${AGENT_TMP_LEGACY_ROOT:-/tmp/claude-1000}
# Other agents' temp paths. None of them exposes a session this janitor can
# recognise, so they wait for the age rule rather than for the budget. The env
# override takes a :-separated list, which is how a test points it at fixtures.
if [ -n "${AGENT_TMP_STALE_PATHS:-}" ]; then
  IFS=: read -r -a STALE_PATHS <<<"$AGENT_TMP_STALE_PATHS"
else
  STALE_PATHS=(/tmp/pi-* /tmp/oc /tmp/opencode)
fi
STATE_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/agent-tmp
STATE_FILE=$STATE_DIR/state

now=$(date +%s)

# GiB with one decimal, the unit the budget is reasoned about in.
gib() {
  awk -v b="${1:-0}" 'BEGIN {
    if (b >= 1073741824) printf "%.1fG", b / 1073741824
    else if (b >= 1048576) printf "%.0fM", b / 1048576
    else printf "%dK", (b + 1023) / 1024
  }'
}

# Disk use in bytes, symlinks not followed: what deleting it would give back.
size_of() {
  local bytes
  bytes=$(du -s --block-size=1 -- "$1" 2>/dev/null | cut -f1)
  echo "${bytes:-0}"
}

# Seconds since the path last changed. A directory's mtime moves when entries
# are added or removed inside it, which is what "touched" means here.
age_of() {
  local mtime
  mtime=$(stat -c %Y -- "$1" 2>/dev/null) || {
    echo 0
    return
  }
  echo $((now - mtime))
}

# Session ids whose registered pid is still running, from Claude Code's own
# registry (pi sessions land in it too, via the claude-peers extension).
live_sessions() {
  local file pid sid
  for file in "$HOME"/.claude/sessions/*.json "$HOME"/.claude-work/sessions/*.json; do
    [ -f "$file" ] || continue
    read -r pid sid < <(jq -r '"\(.pid // "") \(.sessionId // "")"' "$file" 2>/dev/null) || continue
    [ -n "$pid" ] && [ -n "$sid" ] || continue
    [ -d "/proc/$pid" ] || continue
    printf '%s\n' "$sid"
  done
}

# Available and total bytes on the filesystem the agents write to.
free_space() { df --output=avail,size -B1 / 2>/dev/null | tail -1; }

total_agent_bytes() {
  local path total=0
  for path in "$ROOT" "$LEGACY_ROOT" ${STALE_PATHS[@]+"${STALE_PATHS[@]}"}; do
    [ -e "$path" ] || continue
    total=$((total + $(size_of "$path")))
  done
  echo "$total"
}

# One tab-separated row per path: age, size, kind, path. `live` is never
# deleted, `dead` is freed by any rule, `unmanaged` only by the age rule.
candidates() {
  local path dir name age kind
  local -a live_ids=()
  mapfile -t live_ids < <(live_sessions)

  if [ -d "$ROOT" ]; then
    for path in "$ROOT"/*; do
      [ -d "$path" ] || continue
      name=${path##*/}
      if [[ $name =~ ^[0-9]+$ ]]; then
        # The wrappers name the dir after their own pid, which exec keeps, so a
        # missing /proc entry proves the session is gone.
        if [ -d "/proc/$name" ]; then kind=live; else kind=dead; fi
      else
        kind=unmanaged
      fi
      printf '%s\t%s\t%s\t%s\n' "$(age_of "$path")" "$(size_of "$path")" "$kind" "$path"
    done
  fi

  # Before the redirect, every session wrote under /tmp/claude-1000/<cwd>/<uuid>.
  if [ -d "$LEGACY_ROOT" ]; then
    for dir in "$LEGACY_ROOT"/*; do
      [ -d "$dir" ] || continue
      for path in "$dir"/*; do
        [ -d "$path" ] || continue
        name=${path##*/}
        age=$(age_of "$path")
        kind=unmanaged
        if [[ $name =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
          if [ ${#live_ids[@]} -gt 0 ] && printf '%s\n' "${live_ids[@]}" | grep -qx -- "$name"; then
            kind=live
          elif [ "$age" -lt "$LEGACY_IDLE_SECONDS" ]; then
            # Unregistered but written to within the hour: treat as live.
            kind=live
          else
            kind=dead
          fi
        fi
        printf '%s\t%s\t%s\t%s\n' "$age" "$(size_of "$path")" "$kind" "$path"
      done
    done
  fi

  for path in ${STALE_PATHS[@]+"${STALE_PATHS[@]}"}; do
    [ -e "$path" ] || continue
    printf '%s\t%s\t%s\t%s\n' "$(age_of "$path")" "$(size_of "$path")" unmanaged "$path"
  done
}

# Never pull the temp dir out from under the process doing the sweeping.
protected() {
  case "$1" in
    "${TMPDIR:-/nonexistent}" | "${TMPDIR:-/nonexistent}"/*) return 0 ;;
  esac
  return 1
}

cmd_dir() {
  # The caller's pid, not this process's: the wrapper execs into the agent, so its
  # pid is the one the sweeper will look for later.
  local pid=${1:-$PPID}
  # /tmp is world-writable, so someone could have planted the root; only use it
  # when it is ours, and fall back to the ambient TMPDIR rather than break a run.
  if mkdir -p -- "$ROOT" 2>/dev/null && [ -O "$ROOT" ]; then
    chmod 700 -- "$ROOT" 2>/dev/null || true
    mkdir -p -- "$ROOT/$pid"
    printf '%s\n' "$ROOT/$pid"
  else
    printf '%s\n' "${TMPDIR:-/tmp}"
  fi
}

cmd_state() {
  local used avail total
  used=$(total_agent_bytes)
  read -r avail total < <(free_space) || { avail=0; total=1; }
  mkdir -p -- "$STATE_DIR"
  printf '%s %s %s %s\n' "$now" "$(gib "$used")" "${BUDGET_GIB}G" "$avail" >"$STATE_FILE.tmp"
  mv -f -- "$STATE_FILE.tmp" "$STATE_FILE"
}

refresh_state() { "$0" state >/dev/null 2>&1 || true; }

cmd_statusline() {
  local epoch used budget _avail
  if read -r epoch used budget _avail <"$STATE_FILE" 2>/dev/null; then
    if [ $((now - epoch)) -gt "$STATE_TTL_SECONDS" ]; then
      { refresh_state & } 2>/dev/null
      disown || true
    fi
    printf 'tmp %s/%s' "$used" "$budget"
    return
  fi
  { refresh_state & } 2>/dev/null
  disown || true
  printf 'tmp ?'
}

toast() {
  # agent-notify is on PATH only on Linux desktops; elsewhere there is nowhere to toast.
  command -v agent-notify >/dev/null 2>&1 || return 0
  jq -cn --arg message "$1" '{cwd: "/", message: $message}' | agent-notify agent-tmp >/dev/null 2>&1 || true
}

# The rule, shared by both modes: `live` never goes, `dead` goes when it is old
# or when the budget or the free floor is under pressure, `unmanaged` only when old.
# An empty dead dir goes on its own: it holds nothing, and a tree of them is the
# clutter this exists to prevent. The hour keeps a pid recycled mid-start safe.
deletable_now() {
  local age=$1 kind=$2 size=$3
  [ "$kind" = live ] && return 1
  if [ "$kind" = dead ] && [ "$size" -lt 4096 ] && [ "$age" -ge "$LEGACY_IDLE_SECONDS" ]; then return 0; fi
  [ "$age" -ge "$MAX_AGE_SECONDS" ] && return 0
  [ "$kind" = dead ] || return 1
  [ "$over" = 1 ] || [ "$low" = 1 ]
}

# `status` reports, `sweep` acts: the same walk and the same rules.
cmd_sweep() {
  local act=$1
  local age size kind path freed=0 count=0 total_bytes avail total floor_bytes
  local over low table list hidden

  total_bytes=$(total_agent_bytes)
  read -r avail total < <(free_space) || { avail=0; total=1; }
  floor_bytes=$((total * FREE_FLOOR_PCT / 100))
  over=0
  if [ "$total_bytes" -gt "$BUDGET_BYTES" ]; then over=1; fi
  low=0
  if [ "$avail" -lt "$floor_bytes" ]; then low=1; fi

  printf 'agent-tmp: %s in agent temp, budget %s, %s free on / (floor %s%%)\n' \
    "$(gib "$total_bytes")" "$(gib "$BUDGET_BYTES")" "$(gib "$avail")" "$FREE_FLOOR_PCT"

  table=$(mktemp)
  # Oldest first, which is the order an LRU eviction wants.
  candidates | sort -t$'\t' -k1,1nr >"$table"

  if [ "$act" = report ]; then
    list=$(mktemp)
    hidden=0
    while IFS=$'\t' read -r age size kind path; do
      if ! deletable_now "$age" "$kind" "$size" || protected "$path"; then continue; fi
      freed=$((freed + size))
      count=$((count + 1))
      if [ "$size" -lt "$REPORT_FREE_BYTES" ]; then
        hidden=$((hidden + 1))
        continue
      fi
      printf '%s\t%s\t%s\n' "$size" "$kind" "$path" >>"$list"
    done <"$table"
    # Biggest first: the question a report answers is what is holding the space.
    while IFS=$'\t' read -r size kind path; do
      printf '  free  %8s  %-9s %s\n' "$(gib "$size")" "$kind" "$path"
    done < <(sort -t$'\t' -k1,1nr "$list")
    rm -f -- "$list"
    if [ "$hidden" -gt 0 ]; then
      printf '  free  %8s  %-9s and %d smaller path(s)\n' "" "" "$hidden"
    fi

    list=$(mktemp)
    while IFS=$'\t' read -r age size kind path; do
      if [ "$size" -ge "$REPORT_KEEP_BYTES" ] && ! deletable_now "$age" "$kind" "$size"; then
        printf '%s\t%s\t%s\n' "$size" "$kind" "$path" >>"$list"
      fi
    done <"$table"
    rm -f -- "$table"
    while IFS=$'\t' read -r size kind path; do
      printf '  keep  %8s  %-9s %s\n' "$(gib "$size")" "$kind" "$path"
    done < <(sort -t$'\t' -k1,1nr "$list" | head -20)
    rm -f -- "$list"

    printf 'agent-tmp: a sweep would free %s from %d path(s), leaving %s\n' \
      "$(gib "$freed")" "$count" "$(gib $((total_bytes - freed)))"
    return
  fi

  while IFS=$'\t' read -r age size kind path; do
    if ! deletable_now "$age" "$kind" "$size" || protected "$path"; then continue; fi
    if ! rm -rf -- "$path"; then
      printf '  failed %8s  %-9s %s\n' "$(gib "$size")" "$kind" "$path"
      continue
    fi
    printf '  freed  %8s  %-9s %s\n' "$(gib "$size")" "$kind" "$path"
    freed=$((freed + size))
    count=$((count + 1))
    # Re-check the pressure tests against what this deletion just bought.
    total_bytes=$((total_bytes - size))
    if [ "$total_bytes" -le "$BUDGET_BYTES" ]; then over=0; fi
    if [ $((avail + freed)) -ge "$floor_bytes" ]; then low=0; fi
  done <"$table"
  rm -f -- "$table"

  printf 'agent-tmp: freed %s from %d path(s)\n' "$(gib "$freed")" "$count"
  # A quiet sweep stays quiet; a gigabyte or more is worth a toast.
  if [ "$freed" -ge 1073741824 ]; then
    toast "Freed $(gib "$freed") from $count dead agent path(s)"
  fi
  cmd_state
}

# The line the model gets when the disk is under pressure, or nothing. Throttled
# per session so a run of tool calls can't repeat it.
pressure_line() {
  local session=${1:-} avail total throttle last used
  read -r avail total < <(free_space) || return 1
  [ "$avail" -lt "$WARN_FREE_BYTES" ] || return 1
  mkdir -p -- "$STATE_DIR/warned"
  throttle=$STATE_DIR/warned/${session:-global}
  if [ -f "$throttle" ]; then
    last=$(cat -- "$throttle" 2>/dev/null) || last=0
    if [ $((now - last)) -lt "$WARN_EVERY_SECONDS" ]; then return 1; fi
  fi
  printf '%s\n' "$now" >"$throttle"
  used=unknown
  if [ -n "${TMPDIR:-}" ] && [ -d "${TMPDIR:-}" ]; then
    used=$(gib "$(size_of "$TMPDIR")")
  fi
  printf 'Disk: %s free on /. Your temp dir %s holds %s, and dead sessions on this machine are evicted to make room. Delete what this task no longer needs (rm -rf inside it) before downloading or extracting anything large.' \
    "$(gib "$avail")" "${TMPDIR:-none}" "$used"
}

cmd_warn() {
  local session line
  session=$(jq -r '.session_id // ""' 2>/dev/null) || session=""
  line=$(pressure_line "$session") || return 0
  jq -cn --arg line "$line" '{hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $line}}'
}

cmd_warnline() {
  pressure_line "${1:-}" || true
}

case ${1:-status} in
  dir) cmd_dir "${2:-}" ;;
  state) cmd_state ;;
  statusline) cmd_statusline ;;
  status) cmd_sweep report ;;
  sweep) cmd_sweep sweep ;;
  warn) cmd_warn ;;
  warnline) cmd_warnline "${2:-}" ;;
  *)
    printf 'usage: agent-tmp {dir|state|statusline|status|sweep|warn|warnline}\n' >&2
    exit 2
    ;;
esac
