# The janitor: what agents and dev tools leave behind, reclaimed by rule.
#
# Agents write temp files wherever TMPDIR points and nothing removes them, so the
# wrappers point TMPDIR at /tmp/agent/<pid> and this owns that root. Around it sit
# the leftovers with no owner: Claude Code's finished jobs, transcripts nothing
# reads any more, branches merged months ago, worktrees nothing landed in, and
# build dirs in repos nobody has opened since spring.
#
#   (no args)|report  what is here, what a pass would free; deletes nothing
#   plan [--json]     the same as data, one item per line of output
#   apply             the checklist: pick what goes, branches are bundled first
#   run tmp|repo|all  the timers' passes
#   dir [pid]         print (and create) <pid>'s temp dir; wrappers pass their $$
#   state             refresh the cached numbers the widget reads from disk
#   warn              Claude Code PreToolUse hook: one line for the model under pressure
#   warnline          the same line as text, for pi's tool_result hook
#
# Nothing here needs root: every path is owned by the user running the agents.
set -euo pipefail

ROOT=${JANITOR_ROOT:-/tmp/agent}
LEGACY_ROOT=${JANITOR_LEGACY_ROOT:-/tmp/claude-1000}
# A budget, not a cap: it is what the sweep defends by evicting dead sessions.
BUDGET_GIB=${JANITOR_TMP_BUDGET_GIB:-16}
TMP_MAX_AGE_DAYS=${JANITOR_TMP_MAX_AGE_DAYS:-3}
FREE_FLOOR_PCT=${JANITOR_FREE_FLOOR_PCT:-10}
WARN_FREE_GIB=${JANITOR_WARN_FREE_GIB:-10}
# One line per ten minutes is enough to be heard without becoming wallpaper.
WARN_EVERY_SECONDS=${JANITOR_WARN_EVERY_SECONDS:-600}
# Transcripts feed pi-auto-gate's `extract`, which rebuilds the judge dataset from
# them, so the age is a month rather than a week.
TRANSCRIPT_AGE_DAYS=${JANITOR_TRANSCRIPT_AGE_DAYS:-30}
# A Claude Code job's private tmp is garbage once the job has been done this long.
JOB_TMP_AGE_DAYS=${JANITOR_JOB_TMP_AGE_DAYS:-7}
# Rebuildable in minutes with a lockfile and a fast network, so the age is short.
BUILD_DIR_AGE_DAYS=${JANITOR_BUILD_DIR_AGE_DAYS:-60}
BRANCH_IDLE_DAYS=${JANITOR_BRANCH_IDLE_DAYS:-90}
# A legacy dir the session registry has never heard of is only idle-guessed; an
# hour without a write is longer than a live session goes without touching it.
LEGACY_IDLE_SECONDS=3600

BUDGET_BYTES=$((BUDGET_GIB * 1024 * 1024 * 1024))
TMP_MAX_AGE_SECONDS=$((TMP_MAX_AGE_DAYS * 86400))
WARN_FREE_BYTES=$((WARN_FREE_GIB * 1024 * 1024 * 1024))
TRANSCRIPT_AGE_SECONDS=$((TRANSCRIPT_AGE_DAYS * 86400))
JOB_TMP_AGE_SECONDS=$((JOB_TMP_AGE_DAYS * 86400))
BUILD_DIR_AGE_SECONDS=$((BUILD_DIR_AGE_DAYS * 86400))
BRANCH_IDLE_SECONDS=$((BRANCH_IDLE_DAYS * 86400))

# Other agents' temp paths. None of them exposes a session this can recognise, so
# they wait for the age rule. The env override takes a :-separated list, which is
# how a test points it at fixtures.
if [ -n "${JANITOR_STALE_PATHS:-}" ]; then
  IFS=: read -r -a STALE_PATHS <<<"$JANITOR_STALE_PATHS"
else
  STALE_PATHS=(/tmp/pi-* /tmp/oc /tmp/opencode /tmp/jiti /tmp/node-compile-cache)
fi

if [ -n "${JANITOR_REPO_PARENTS:-}" ]; then
  IFS=: read -r -a REPO_PARENTS <<<"$JANITOR_REPO_PARENTS"
else
  REPO_PARENTS=("$HOME/dev")
fi
if [ -n "${JANITOR_REPO_SINGLES:-}" ]; then
  IFS=: read -r -a REPO_SINGLES <<<"$JANITOR_REPO_SINGLES"
else
  REPO_SINGLES=("$HOME/nixos")
fi

CLAUDE_DIRS=("$HOME/.claude" "$HOME/.claude-work")
STATE_DIR=${JANITOR_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/janitor}
STATE_FILE=$STATE_DIR/state.json
PLAN_FILE=$STATE_DIR/plan.json
BUNDLE_DIR=$STATE_DIR/bundles

now=$(date +%s)

# GiB with one decimal, the unit the budget is reasoned about in.
gib() {
  awk -v b="${1:-0}" 'BEGIN {
    if (b >= 1073741824) printf "%.1fG", b / 1073741824
    else if (b >= 1048576) printf "%.0fM", b / 1048576
    else if (b > 0) printf "%dK", (b + 1023) / 1024
    else printf "0K"
  }'
}

# Disk use in bytes, symlinks not followed: what deleting it would give back.
size_of() {
  local bytes
  bytes=$(du -s --block-size=1 -- "$1" 2>/dev/null | cut -f1)
  echo "${bytes:-0}"
}

# Bytes a single file occupies.
file_bytes() {
  local bytes
  bytes=$(stat -c %s -- "$1" 2>/dev/null) || {
    echo 0
    return
  }
  echo "$bytes"
}

# Seconds since the path last changed. A directory's mtime moves when entries are
# added or removed inside it, which is what "touched" means here.
age_of() {
  local mtime
  mtime=$(stat -c %Y -- "$1" 2>/dev/null) || {
    echo 0
    return
  }
  echo $((now - mtime))
}

# Available and total bytes on the filesystem the agents write to.
free_space() { df --output=avail,size -B1 / 2>/dev/null | tail -1; }

toast() {
  # notify-send ships only on Linux; a host without a notification daemon just fails quietly.
  command -v notify-send >/dev/null 2>&1 || return 0
  notify-send --app-name=janitor janitor "$1" >/dev/null 2>&1 || true
}

# Never delete the temp dir of the process doing the sweeping.
protected() {
  case "$1" in
    "${TMPDIR:-/nonexistent}" | "${TMPDIR:-/nonexistent}"/*) return 0 ;;
  esac
  case "$1" in
    "$STATE_DIR" | "$STATE_DIR"/*) return 0 ;;
  esac
  return 1
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

# Every process's working directory, once, so the repo scans can ask "is anything
# running in here?" without a /proc walk per directory.
proc_cwds() {
  local proc cwd
  for proc in /proc/[0-9]*; do
    cwd=$(readlink -- "$proc/cwd" 2>/dev/null) || continue
    printf '%s\n' "$cwd"
  done
}

# True when some process is working inside the given path.
anything_running_in() {
  local path=$1 cwd
  [ -s "${CWD_CACHE:-/nonexistent}" ] || return 1
  while IFS= read -r cwd; do
    case "$cwd" in
      "$path" | "$path"/*) return 0 ;;
    esac
  done <"$CWD_CACHE"
  return 1
}

is_repo() { [ -e "$1/.git" ]; }

# Every repository the janitor looks at: the checkouts under ~/dev plus the ones
# that are a checkout on their own, like ~/nixos.
repos() {
  local parent repo
  for parent in ${REPO_PARENTS[@]+"${REPO_PARENTS[@]}"}; do
    [ -d "$parent" ] || continue
    for repo in "$parent"/*; do
      is_repo "$repo" && printf '%s\n' "$repo"
    done
  done
  for repo in ${REPO_SINGLES[@]+"${REPO_SINGLES[@]}"}; do
    is_repo "$repo" && printf '%s\n' "$repo"
  done
}

# The branch a merged-branch decision is measured against.
default_branch() {
  local repo=$1 branch
  branch=$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null) || branch=""
  if [ -n "$branch" ]; then
    printf '%s\n' "${branch#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$repo" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null; then
      printf '%s\n' "$branch"
      return 0
    fi
  done
  return 1
}

# A short label for the widget's rows: home truncated, session uuids cut to eight
# characters, and Claude's project slugs stripped of their "-home-<user>-dev-"
# prefix so the row says which project rather than repeating the home directory.
label_for() {
  local path=$1 tilde='~'
  case "$path" in
    "$HOME"/dev/*) path=${path#"$HOME"/dev/} ;;
    "$HOME"/*) path="$tilde/${path#"$HOME"/}" ;;
    /tmp/*) path=${path#/tmp/} ;;
  esac
  printf '%s\n' "$path" | sed -E '
    s@^~/?\.claude(-work)?/(projects|jobs)/@@
    s@^claude-1000/@@
    s@^-home-[a-z0-9]+-(dev-)?@@
    s@([0-9a-f]{8})-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}@\1@g
  '
}

# The repo that owns a path, for re-checking the build-dir rule at apply time,
# when the plan may be an hour old and the directory may have been used since.
repo_of_path() {
  local path=$1
  while [ -n "$path" ] && [ "$path" != "/" ]; do
    if [ -e "$path/.git" ]; then
      printf '%s\n' "$path"
      return 0
    fi
    path=$(dirname -- "$path")
  done
  return 1
}

# Membership in the roster, so an id naming a repo nobody scans is refused.
is_known_repo() {
  local repo
  while IFS= read -r repo; do
    [ "$repo" = "$1" ] && return 0
  done < <(repos)
  return 1
}

# A transcript is a session .jsonl under a projects directory, never a memory file.
in_projects() {
  local dir
  case "$1" in *.jsonl) ;; *) return 1 ;; esac
  for dir in "${CLAUDE_DIRS[@]}"; do
    case "$1" in "$dir"/projects/*) return 0 ;; esac
  done
  return 1
}

# A job tmp is exactly <claude dir>/jobs/<id>/tmp.
in_jobs() {
  local dir
  case "$1" in */tmp) ;; *) return 1 ;; esac
  for dir in "${CLAUDE_DIRS[@]}"; do
    case "$1" in "$dir"/jobs/*/tmp) return 0 ;; esac
  done
  return 1
}

# Branches that some worktree has checked out; git will not delete those.
checked_out_branches() {
  git -C "$1" worktree list --porcelain 2>/dev/null | awk '/^branch / {sub("refs/heads/", "", $2); print $2}'
}
