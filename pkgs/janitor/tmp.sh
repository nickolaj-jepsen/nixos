# One tab-separated row per path: age, size, kind, path. `live` is never
# deleted, `dead` is freed by any rule, `unmanaged` only by the age rule.
tmp_candidates() {
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

total_tmp_bytes() {
  local path total=0
  for path in "$ROOT" "$LEGACY_ROOT" ${STALE_PATHS[@]+"${STALE_PATHS[@]}"}; do
    [ -e "$path" ] || continue
    total=$((total + $(size_of "$path")))
  done
  echo "$total"
}

# The tmp rule, shared by the report and the sweep: `live` never goes, `dead` goes
# when it is old or when the budget or the free floor is under pressure,
# `unmanaged` only when old. An empty dead dir goes on its own: it holds nothing,
# and a tree of them is the clutter this exists to prevent. The hour keeps a pid
# recycled mid-start safe.
tmp_deletable() {
  local age=$1 kind=$2 size=$3
  [ "$kind" = live ] && return 1
  if [ "$kind" = dead ] && [ "$size" -lt 4096 ] && [ "$age" -ge "$LEGACY_IDLE_SECONDS" ]; then return 0; fi
  [ "$age" -ge "$TMP_MAX_AGE_SECONDS" ] && return 0
  [ "$kind" = dead ] || return 1
  [ "$over" = 1 ] || [ "$low" = 1 ]
}

# The 15-minute pass: agent temp, finished jobs, other agents' strays. `verbose`
# is what a person running it by hand gets; the timer stays quiet unless it frees.
cmd_tmp_sweep() {
  local verbose=${1:-quiet}
  local age size kind path freed=0 count=0 total_bytes avail total floor_bytes
  local over low table

  total_bytes=$(total_tmp_bytes)
  read -r avail total < <(free_space) || { avail=0; total=1; }
  floor_bytes=$((total * FREE_FLOOR_PCT / 100))
  over=0
  if [ "$total_bytes" -gt "$BUDGET_BYTES" ]; then over=1; fi
  low=0
  if [ "$avail" -lt "$floor_bytes" ]; then low=1; fi

  if [ "$verbose" = verbose ]; then
    printf 'janitor: %s in agent temp, budget %s, %s free on / (floor %s%%)\n' \
      "$(gib "$total_bytes")" "$(gib "$BUDGET_BYTES")" "$(gib "$avail")" "$FREE_FLOOR_PCT"
  fi

  table=$(mktemp)
  # Oldest first, which is the order an LRU eviction wants.
  tmp_candidates | sort -t$'\t' -k1,1nr >"$table"

  while IFS=$'\t' read -r age size kind path; do
    if ! tmp_deletable "$age" "$kind" "$size" || protected "$path"; then continue; fi
    if ! rm -rf -- "$path"; then
      printf '  failed  %8s  %-9s %s\n' "$(gib "$size")" "$kind" "$path"
      continue
    fi
    [ "$verbose" = verbose ] && printf '  freed   %8s  %-9s %s\n' "$(gib "$size")" "$kind" "$path"
    freed=$((freed + size))
    count=$((count + 1))
    # Re-check the pressure tests against what this deletion just bought.
    total_bytes=$((total_bytes - size))
    if [ "$total_bytes" -le "$BUDGET_BYTES" ]; then over=0; fi
    if [ $((avail + freed)) -ge "$floor_bytes" ]; then low=0; fi
  done <"$table"
  rm -f -- "$table"

  printf 'janitor: freed %s from %d temp path(s)\n' "$(gib "$freed")" "$count"
  # A quiet sweep stays quiet; a gigabyte or more is worth a toast.
  if [ "$freed" -ge 1073741824 ]; then
    toast "Freed $(gib "$freed") from $count dead temp path(s)"
  fi
  cmd_state
}

cmd_dir() {
  # The caller's pid, not this process's: the wrapper execs into the agent, so its
  # pid is the one the sweep will look for later.
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

# The numbers the widget's pill reads instead of scanning: disk, temp usage, and
# the totals of the last full plan. Cheap by construction, so it can run often.
cmd_state() {
  local print=${1:-} used avail total pct reclaim=0 dead_bytes=0
  used=$(total_tmp_bytes)
  read -r avail total < <(free_space) || { avail=0; total=1; }
  pct=$((total > 0 ? (total - avail) * 100 / total : 0))
  if [ -f "$PLAN_FILE" ]; then
    reclaim=$(jq -r '.reclaim.bytes // 0' "$PLAN_FILE" 2>/dev/null) || reclaim=0
    dead_bytes=$(jq -r '.tmp.dead // 0' "$PLAN_FILE" 2>/dev/null) || dead_bytes=0
  fi
  mkdir -p -- "$STATE_DIR"
  jq -cn \
    --argjson generated "$now" \
    --argjson avail "$avail" \
    --argjson total "$total" \
    --argjson pct "$pct" \
    --argjson used "$used" \
    --argjson budget "$BUDGET_BYTES" \
    --argjson dead "$dead_bytes" \
    --argjson reclaim "$reclaim" \
    '{generated: $generated,
      disk: {avail: $avail, total: $total, usedPct: $pct},
      tmp: {used: $used, budget: $budget, dead: $dead},
      reclaim: {bytes: $reclaim}}' >"$STATE_FILE.tmp"
  mv -f -- "$STATE_FILE.tmp" "$STATE_FILE"
  [ "$print" = print ] && cat -- "$STATE_FILE"
  return 0
}

# The line the model gets when the disk is under pressure, or nothing. Throttled
# per session so a run of tool calls cannot repeat it.
pressure_line() {
  local session=${1:-} avail total throttle last used
  read -r avail total < <(free_space) || return 1
  [ "$avail" -lt "$WARN_FREE_BYTES" ] || return 1
  mkdir -p -- "$STATE_DIR/warned"
  # One file per session id; without this they accumulate for the life of the
  # machine, and STATE_DIR is exactly what the sweep refuses to prune.
  find "$STATE_DIR/warned" -type f -mtime +1 -delete 2>/dev/null || true
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
