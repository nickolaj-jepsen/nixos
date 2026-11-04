#!/usr/bin/env bash
# The /flow scenarios' half of the harness: the review harness's isolation, plus
# a starter that loads both packages, the flow skills and a replay provider, so
# a flow's steps run without a model and without spending tokens.
#
# What a scenario adds to the review harness:
#   flow_init <name>        the scratch tree, plus <name>.turns.json as FIXTURE
#   flow_settings <json>    the scratch agent dir's `flow` key (D27)
#   flow_fixture            a repo with a base branch and a feature on top
#   flow_start [pi argv]    pi with parent, core, the skills and the provider
#   flow_plan_dir <slug>    where the flow keeps BRIEF.md, HANDOFF.md, FLOW.json
#   flow_chain              each session's file, parent, model and level
#
# The scratch tree keeps the review harness's /tmp/tuicr-review-scn prefix
# because scenario_init owns it; a red flow run leaves the same tree and pane
# log behind, which is what a report needs.
set -euo pipefail

FLOW_SCENARIO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../review/scenario/lib.sh
. "$FLOW_SCENARIO_DIR/../../review/scenario/lib.sh"

# The review harness's scratch tree, named after this scenario, with this
# scenario's replay turns as the provider's script.
flow_init() {
  local name="${1:?usage: flow_init <name>}"
  scenario_init "$name"
  FLOW_TURNS=$FLOW_SCENARIO_DIR/$name.turns.json
  [ -f "$FLOW_TURNS" ] || {
    printf 'flow: no turns file at %s\n' "$FLOW_TURNS" >&2
    return 1
  }
  export FLOW_TURNS
}

# The scratch agent dir's `flow` setting, which the wrapper deep-merges into the
# settings it installs at launch. The leaf ships no `flow` key, so this is the
# only layer a scenario sets (D27).
flow_settings() {
  local json="${1:?usage: flow_settings <json>}"
  printf '{"flow": %s}\n' "$json" >"$SCENARIO_AGENT/settings.json"
}

# A repository with something to review: two commits on `main`, a `origin`
# whose default is `main`, and a `feature` branch on top.
flow_fixture() {
  local repo=$SCENARIO_FIXTURE
  local who=(-c user.email=flow@example.invalid -c user.name=Flow)
  git -C "$repo" init -q -b main
  printf 'export const value = 1;\n' >"$repo/a.ts"
  printf 'export function add(a: number, b: number) {\n  return a + b;\n}\n' >"$repo/b.ts"
  git -C "$repo" add .
  git -C "$repo" "${who[@]}" commit -qm "fixture"
  git -C "$repo" init -q --bare "$SCENARIO_ROOT/origin.git"
  git -C "$repo" remote add origin "$SCENARIO_ROOT/origin.git"
  git -C "$repo" push -q origin main
  git -C "$repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  git -C "$repo" checkout -q -b feature
  printf 'export const value = 2;\n' >"$repo/a.ts"
  printf 'export const doubled = (n: number) => n * 2;\n' >"$repo/c.ts"
  git -C "$repo" add .
  git -C "$repo" "${who[@]}" commit -qm "feature"
  git -C "$repo" push -q -u origin feature
}

# pi on the built tree: both packages, the flow skills (through the parent
# package's manifest, so a missing `skills` entry shows here), and the replay
# provider answering as fixture/replay and fixture/deep. Extra argv is appended.
flow_start() {
  local ext
  ext=$(scenario_extensions)
  local cmd="cd $(printf %q "$SCENARIO_FIXTURE") && $SCENARIO_ENV FIXTURE=$(printf %q "$FLOW_TURNS") exec pi --no-extensions -e $(printf %q "$ext/parent") -e $(printf %q "$ext/core") -e $(printf %q "$ext/parent/flow/scenario/fixture-provider.ts") --session-dir $(printf %q "$SCENARIO_SESSIONS") --model fixture/replay"
  local arg
  for arg in "$@"; do cmd+=" $(printf %q "$arg")"; done
  scenario_tmux new-session -d -s pi -x "$SCENARIO_COLS" -y "$SCENARIO_LINES" "$cmd"
  scenario_tmux pipe-pane -t pi -o "cat > $SCENARIO_LOG"
  scenario_wait 'escape interrupt|commands ·' 20
}

# A flow's plan directory under the scratch HOME, which is where `homedir()`
# points: <project> is the main checkout's directory name.
flow_plan_dir() {
  local slug="${1:?usage: flow_plan_dir <slug>}"
  printf '%s\n' "$SCENARIO_HOME/.local/share/agents/$(basename "$SCENARIO_FIXTURE")/plans/$slug"
}

# The last entry of a type in one session file, printed by `filter`; empty when
# the file never recorded one.
flow_last_entry() {
  local file="${1:?}" type="${2:?}" filter="${3:?}"
  jq -rc "select(.type == \"$type\") | $filter" "$file" | tail -1
}

# One tab-separated line per session in the scratch dir, oldest first:
# file, its header's parentSession, the last provider/model, the last thinking
# level. What a step bound to proves its model and level with.
flow_chain() {
  local file parent model thinking
  for file in $(ls -tr "$SCENARIO_SESSIONS"/*.jsonl 2>/dev/null); do
    parent=$(head -1 "$file" | jq -r '.parentSession // "-"')
    model=$(flow_last_entry "$file" model_change '"\(.provider)/\(.modelId)"')
    thinking=$(flow_last_entry "$file" thinking_level_change ".thinkingLevel")
    printf '%s\t%s\t%s\t%s\n' "$(basename "$file")" "$parent" "$model" "$thinking"
  done
}
