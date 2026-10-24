#!/usr/bin/env bash
# Claude Code's worktree hooks, backed by `wt`: EnterWorktree, `claude -w` and
# agent isolation create through `wt create`, so their worktrees share the
# ~/worktrees/<repo>/ layout and wt's removal rule with pi and opencode. One
# verb per hook event, the hook JSON on stdin.
#
# A hooked worktree is opaque to Claude Code: it no longer removes an agent's
# untouched worktree (`subagent-stop` does), and ExitWorktree's remove always
# asks for discard_changes, since it cannot see what would be lost.
set -euo pipefail

verb=${1:?usage: claude-worktree-hooks <verb>}
shift
[ "$verb" = park ] || input=$(cat)
field() { jq -r --arg k "$1" '.[$k] // empty' <<<"$input"; }

# Hooks run as direct children of the claude process.
claude_pid=$PPID

# `wt status` row of the worktree holding $1:
# name path registered branch state ahead behind locked age safe_clean is_main default_branch …
wt_row() {
    local top
    top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || return 1
    top=$(realpath "$top")
    (cd "$top" && wt status 2>/dev/null) | awk -F'\x1f' -v p="$top" '$2 == p { print; found = 1; exit } END { exit !found }'
}
read_row() { IFS=$'\x1f' read -r name path _ branch _ _ _ _ _ safe is_main default _ <<<"$1"; }

# Scripted runs (`claude -p`, the SDK, a pi tool calling claude) have no terminal
# and must never take a worktree with them.
interactive() {
    case "$(readlink "/proc/$1/fd/0" 2>/dev/null)" in /dev/pts/* | /dev/tty*) ;; *) return 1 ;; esac
}

# Keyed by pid and start time, so it survives /clear and /resume but never
# matches a later claude that reused the pid. No /proc (darwin): no marker.
launch_marker() {
    local stat
    stat=$(<"/proc/$claude_pid/stat") 2>/dev/null || return 1
    # Fields after `comm`, which may hold spaces; starttime is field 22 overall.
    local -a rest
    read -ra rest <<<"${stat##*) }"
    printf '%s/claude-launch/%s-%s\n' "${XDG_RUNTIME_DIR:-/tmp}" "$claude_pid" "${rest[19]}"
}

ancestors() {
    local pid=$1 out="" stat
    while [ "$pid" -gt 1 ] 2>/dev/null; do
        out+=" $pid"
        stat=$(<"/proc/$pid/stat") 2>/dev/null || break
        local -a rest
        read -ra rest <<<"${stat##*) }"
        pid=${rest[1]}
    done
    printf '%s\n' "$out"
}

# Whether a process other than $2's pids lives in $1: shells and editors count,
# the session's own launching shell does not (it loses its cwd as after `wt clean`).
in_use() {
    local root=$1 ours=" $2 " d pid cwd
    [ -d /proc/self ] || return 0
    for d in /proc/[0-9]*; do
        pid=${d#/proc/}
        case "$ours" in *" $pid "*) continue ;; esac
        cwd=$(readlink "$d/cwd" 2>/dev/null) || continue
        case "$cwd" in "$root" | "$root"/*) return 0 ;; esac
    done
    return 1
}

case "$verb" in
create)
    # No wt: print nothing and Claude Code creates the worktree itself.
    command -v wt >/dev/null 2>&1 || exit 0
    cd "$(field cwd)"
    exec wt create "$(field name)"
    ;;

remove)
    # Reached only after ExitWorktree's discard_changes or a remove picked at
    # exit, so the work is dropped as asked.
    target=$(field worktree_path)
    row=$(wt_row "$target") || {
        echo "wt does not know a worktree at $target" >&2
        exit 1
    }
    read_row "$row"
    cd "$path"
    wt clean --force "$name" >&2
    ;;

subagent-stop)
    # Claude Code removes an isolated agent's untouched worktree itself, but not
    # a hooked one. A worktree with changes stays for the parent, as natively.
    agent=$(field agent_id)
    [ -n "$agent" ] || exit 0
    row=$(wt_row "$(field cwd)") || exit 0
    read_row "$row"
    [ "${path##*/}" = "agent-$agent" ] && [ "$safe" = 1 ] || exit 0
    cd "$path"
    wt clean "$name" >&2 || true
    ;;

session-start)
    interactive "$claude_pid" || exit 0
    marker=$(launch_marker) || exit 0
    # Only the process's first session is its launch; /clear and /resume keep it.
    [ -e "$marker" ] && exit 0
    mkdir -p "${marker%/*}"
    field cwd >"$marker"
    ;;

session-end)
    case "$(field reason)" in clear | resume) exit 0 ;; esac
    marker=$(launch_marker) || exit 0
    [ -f "$marker" ] || exit 0
    launch=$(<"$marker")
    rm -f "$marker"
    # SessionEnd hooks get a short deadline; the decision runs after claude exits.
    setsid -f "$BASH" "$0" park "$launch" "$claude_pid" "$(ancestors $$)" </dev/null >/dev/null 2>&1
    ;;

park)
    # The launch worktree goes only when nothing can be lost: clean, nothing
    # ahead, not parked on the default branch, nobody else inside. A worktree
    # entered with EnterWorktree is left to Claude Code's own exit prompt.
    launch=$1 claude=$2 ours=$3
    cd /
    for _ in $(seq 50); do
        [ -e "/proc/$claude" ] || break
        sleep 0.2
    done
    row=$(wt_row "$launch") || exit 0
    read_row "$row"
    [ "$is_main" = 0 ] && [ "$safe" = 1 ] && [ "$branch" != "$default" ] || exit 0
    in_use "$path" "$ours" && exit 0
    cd "$path"
    wt clean "$name"
    ;;

*)
    echo "claude-worktree-hooks: unknown verb $verb" >&2
    exit 1
    ;;
esac
