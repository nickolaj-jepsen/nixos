# shellcheck disable=SC2034  # read by record.sh, which sources this
# linear-issue from the You should know card, sourced by record.sh: Haiku walks a small
# project whose test script swallows a failing check, the built-in side agent flags it, and
# the card's Linear issue button drafts an issue from the insight.
#
# The card is the side agent's call, made on every 6th step of a turn, so the turn takes 12
# tool calls for two looks, and prints the test script's exit code next to its FAIL. A run
# where it flags nothing (or something else) is a run to repeat. Nothing is filed: no step presses Create,
# Linear's write tools stay unapproved, and record.sh drops the recording if one was called.

L=mcp__claude_ai_Linear__
TUI_ARGS=(--full)
CLAUDE_ARGS=(
  --model haiku
  --allowedTools "Read,Glob,Bash(ls:*),Bash(echo:*),Bash(sh scripts/test.sh),${L}get_user,${L}list_teams,${L}list_issue_statuses,${L}list_issue_labels,${L}list_projects,${L}list_issues"
)
READY_LOG='claude.ai Linear": Successfully connected'
FORBIDDEN_LOG='Linear__save_'

setup() {
  mkdir -p "$1/src" "$1/scripts" "$1/.github/workflows"
  cat >"$1/README.md" <<'EOF'
# sync-worker

Pulls orders from the shop API every minute. `scripts/test.sh` runs the checks; CI runs
it on every push and blocks the merge when it fails.
EOF
  cat >"$1/src/sync.sh" <<'EOF'
#!/bin/sh
# Fetches a page of orders, backing off on 429.
delay=1
while :; do
  status=$(curl -s -o /tmp/orders.json -w '%{http_code}' "$SHOP_API/orders")
  [ "$status" != 429 ] && break
  sleep "$delay"
  delay=$((delay * 2))
done
EOF
  cat >"$1/src/config.sh" <<'EOF'
SHOP_API=https://shop.example/api
MAX_DELAY=60
EOF
  cat >"$1/CHANGELOG.md" <<'EOF'
## 0.3.0
- Back off on 429 instead of failing the sync.
EOF
  cat >"$1/scripts/test.sh" <<'EOF'
#!/bin/sh
# The sync worker's checks.
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fi; }
check "backoff doubles" 'grep -q "delay \* 2" src/sync.sh'
check "honors Retry-After" 'grep -q "Retry-After" src/sync.sh'
echo "checks done"
EOF
  cat >"$1/.github/workflows/ci.yml" <<'EOF'
name: ci
on: push
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: sh scripts/test.sh
EOF
}

demo() {
  type_slow 'Take a quick look at this project, one tool call per step: list the files; read README.md, src/sync.sh, src/config.sh, scripts/test.sh, .github/workflows/ci.yml and CHANGELOG.md; run sh scripts/test.sh; echo exit=$? after running it again; list src/, scripts/ and .github/workflows/. Then sum it up in two sentences.' 0.02
  pause 1
  press Enter
  # The card comes once the side agent has looked, usually after the turn ends.
  wait_for 'Learn more' 240
  pause 2.5
  press 1 # Learn more
  wait_for 'Linear issue' 120
  pause 2.5
  key="$(screen | grep -oE '[3-7]: ?Linear issue' | head -1 | cut -c1)"
  press "${key:-3}"
  wait_for 'Create & open' 180
  pause 4
}
