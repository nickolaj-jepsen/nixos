#!/usr/bin/env bash
# Harness for the /review scenarios: a private tmux server, its own XDG tree,
# its own agent dir and a fixture repository per scenario. Nothing here touches
# the owner's tuicr store, their pi session or their agent files, and two
# scenarios can run at once because every socket and directory is named after
# the scenario.
#
# Usage, from a scenario script:
#   . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
#   scenario_init smoke          # scratch dirs, tmux server, cleanup trap
#   scenario_fixture             # a repo with one uncommitted change
#   scenario_start               # pi with this worktree's extensions
#   scenario_type /review; scenario_keys Enter
#   scenario_wait "review: not implemented yet"
#   scenario_pass
#
# The pane is read, never the session file: a scenario proves what the owner
# would see. Assertions fail with the pane dumped, so a red run explains itself.

set -euo pipefail

SCENARIO_COLS=${SCENARIO_COLS:-120}
SCENARIO_LINES=${SCENARIO_LINES:-40}

# bash, because tmux runs the command string with the owner's login shell.
SCENARIO_SHELL=/run/current-system/sw/bin/bash

scenario_repo() {
  git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel
}

# The built extensions, so a scenario runs the code this worktree committed.
scenario_extensions() {
  if [ -n "${PI_REVIEW_EXT:-}" ]; then
    printf '%s\n' "$PI_REVIEW_EXT"
    return 0
  fi
  if [ -z "${SCENARIO_EXT:-}" ]; then
    SCENARIO_EXT=$(cd "$(scenario_repo)" && nix build .#pi-extensions --no-link --print-out-paths | tail -1)
    [ -n "$SCENARIO_EXT" ] || {
      printf 'scenario: could not build pi-extensions\n' >&2
      return 1
    }
  fi
  printf '%s\n' "$SCENARIO_EXT"
}

scenario_init() {
  local name="${1:?usage: scenario_init <name>}"
  # A second run of the same script gets its own tree and its own tmux server,
  # so a reviewer re-running one never kills an item's scenario.
  local id="${SCENARIO_ID:-$$}"
  SCENARIO_NAME=$name
  SCENARIO_ROOT=/tmp/tuicr-review-scn/$name-$id
  SCENARIO_FIXTURE=$SCENARIO_ROOT/repo
  SCENARIO_AGENT=$SCENARIO_ROOT/agent
  SCENARIO_SESSIONS=$SCENARIO_ROOT/sessions
  SCENARIO_RUNTIME=$SCENARIO_ROOT/run
  SCENARIO_TMUX=pi-review-$name-$id
  SCENARIO_LOG=$SCENARIO_ROOT/pi.log
  XDG_DATA_HOME=$SCENARIO_ROOT/data
  XDG_CONFIG_HOME=$SCENARIO_ROOT/config
  XDG_RUNTIME_DIR=$SCENARIO_RUNTIME
  TMPDIR=$SCENARIO_ROOT/tmp
  export SCENARIO_NAME SCENARIO_ROOT SCENARIO_FIXTURE SCENARIO_AGENT SCENARIO_SESSIONS
  export SCENARIO_RUNTIME SCENARIO_TMUX SCENARIO_LOG XDG_DATA_HOME XDG_CONFIG_HOME
  export XDG_RUNTIME_DIR TMPDIR
  # A scenario stays off the owner's hub and never reaches the network.
  export AGENT_HUB_HIDDEN=1 PI_OFFLINE=1

  scenario_stop
  rm -rf "$SCENARIO_ROOT"
  mkdir -p "$SCENARIO_FIXTURE" "$SCENARIO_AGENT" "$SCENARIO_SESSIONS"
  mkdir -p "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$TMPDIR"
  mkdir -p "$SCENARIO_RUNTIME"
  chmod 700 "$SCENARIO_RUNTIME"
  # The scratch agent dir needs the owner's theme and keybindings, or the
  # chrome's shortcuts read as conflicts and the startup banner fails.
  ln -sfn "$HOME/.pi/agent/themes" "$SCENARIO_AGENT/themes"
  ln -sfn "$HOME/.pi/agent/keybindings.json" "$SCENARIO_AGENT/keybindings.json"
  # The tmux server holds the environment its sessions start with.
  SCENARIO_ENV="XDG_DATA_HOME=$(printf %q "$XDG_DATA_HOME") XDG_CONFIG_HOME=$(printf %q "$XDG_CONFIG_HOME") XDG_RUNTIME_DIR=$(printf %q "$XDG_RUNTIME_DIR") PI_CODING_AGENT_DIR=$(printf %q "$SCENARIO_AGENT") TMPDIR=$(printf %q "$TMPDIR") AGENT_HUB_HIDDEN=1 PI_OFFLINE=1"
  trap scenario_stop EXIT
  # Options in the same invocation as the first session: a server that has not
  # been started yet would otherwise run that session with the owner's shell.
  scenario_tmux new-session -d -s boot "sleep 3600" \
    \; set-option -g default-shell "$SCENARIO_SHELL" \
    \; set-option -g extended-keys on \
    \; set-option -g extended-keys-format csi-u \
    \; set-option -g status off
}

scenario_tmux() {
  tmux -L "$SCENARIO_TMUX" "$@"
}

# A repository a review has something to show for: one committed file, one
# uncommitted change on top.
scenario_fixture() {
  local repo=$SCENARIO_FIXTURE
  git -C "$repo" init -q -b main
  printf 'export const value = 1;\n' >"$repo/a.ts"
  printf 'export function add(a: number, b: number) {\n  return a + b;\n}\n' >"$repo/b.ts"
  git -C "$repo" add .
  git -C "$repo" -c user.email=review@example.invalid -c user.name=Review commit -qm "fixture"
  printf 'export const value = 2;\n' >"$repo/a.ts"
}

# Start pi in the fixture, on the built extensions, with any extra pi argv.
scenario_start() {
  local ext
  ext=$(scenario_extensions)
  local cmd="cd $(printf %q "$SCENARIO_FIXTURE") && $SCENARIO_ENV exec pi --no-extensions -e $(printf %q "$ext/parent") --session-dir $(printf %q "$SCENARIO_SESSIONS")"
  local arg
  for arg in "$@"; do cmd+=" $(printf %q "$arg")"; done
  scenario_tmux new-session -d -s pi -x "$SCENARIO_COLS" -y "$SCENARIO_LINES" "$cmd"
  # A file, not a pipe: pi draws a TUI only when its output is the terminal.
  scenario_tmux pipe-pane -t pi -o "cat > $SCENARIO_LOG"
  # The prompt, not the splash: pi accepts typing once the editor is up.
  scenario_wait 'escape interrupt|commands ·' 20
}

scenario_pane() {
  scenario_tmux capture-pane -p -t pi -J | sed -e 's/[[:space:]]*$//'
}

# The pane into a variable first: `capture-pane | grep -q` kills the capture with
# SIGPIPE once grep has its answer, and under pipefail that reads as a failure.
scenario_match() {
  local pattern=$1 frame
  frame=$(scenario_pane)
  grep -qE -- "$pattern" <<<"$frame"
}

scenario_wait() {
  local pattern="${1:?usage: scenario_wait <regex> [seconds]}"
  local limit="${2:-20}"
  local _
  for _ in $(seq $((limit * 5))); do
    if scenario_match "$pattern"; then
      return 0
    fi
    sleep 0.2
  done
  printf "scenario: no match for '%s' after %ss, pane follows:\n" "$pattern" "$limit" >&2
  scenario_pane >&2
  exit 1
}

scenario_assert_has() {
  local pattern="${1:?usage: scenario_assert_has <regex>}"
  if ! scenario_match "$pattern"; then
    printf "scenario: expected '%s' on the pane, got:\n" "$pattern" >&2
    scenario_pane >&2
    exit 1
  fi
}

scenario_assert_lacks() {
  local pattern="${1:?usage: scenario_assert_lacks <regex>}"
  if scenario_match "$pattern"; then
    printf "scenario: did not expect '%s' on the pane, got:\n" "$pattern" >&2
    scenario_pane >&2
    exit 1
  fi
}

scenario_type() {
  scenario_tmux send-keys -t pi -l -- "$*"
}

scenario_keys() {
  scenario_tmux send-keys -t pi -- "$@"
}

scenario_resize() {
  scenario_tmux resize-window -t pi -x "${1:?cols}" -y "${2:?lines}"
  sleep 0.5
}

scenario_pass() {
  printf 'PASS\n'
}

scenario_stop() {
  tmux -L "${SCENARIO_TMUX:-none}" kill-server 2>/dev/null || true
}
