# fireproof.agents.live: keeps the agents checkout's plugin builds current and says
# when what loads from it differs from what a switch would give.
#   build  rebuild the plugins' dist/ (a turbo cache hit when nothing changed)
#   check  print one line per problem, nothing when all is well
#   hook   check, as a Claude Code SessionStart systemMessage
# CHECKOUT, PINNED_REV, SKILLS and PLUGINS come from Nix (agent-skills.nix).

state="${XDG_STATE_HOME:-$HOME/.local/state}/agents"
log="$state/live-build.log"

build() {
  [ -d "$CHECKOUT" ] || return 0
  mkdir -p "$state"
  local filters=() name
  for name in $PLUGINS; do
    if [ -d "$CHECKOUT/apps/$name" ]; then filters+=("--filter=./apps/$name"); fi
  done
  # Concurrent launches would write the same dist/ files.
  exec 9>"$state/live-build.lock"
  flock 9
  # The checkout's own devshell: its node, pnpm and CLAUDE_BIN, so the turbo cache is
  # the one `pnpm turbo run build` there uses.
  if (cd "$CHECKOUT" && direnv exec . pnpm turbo run build "${filters[@]}" --output-logs=errors-only) >"$log.new" 2>&1; then
    rm -f "$log" "$log.new"
  else
    mv "$log.new" "$log"
  fi
  exec 9>&-
}

check() {
  if [ ! -d "$CHECKOUT" ]; then
    echo "agents live: $CHECKOUT is missing, so its skills and plugins don't load."
    return
  fi
  [ ! -e "$log" ] || echo "agents live: the plugin build failed, so the previous dist/ loads. See $log."

  if ! git -C "$CHECKOUT" merge-base --is-ancestor "$PINNED_REV" HEAD 2>/dev/null; then
    echo "agents live: the checkout ($(git -C "$CHECKOUT" rev-parse --short HEAD 2>/dev/null)) lacks the pinned ${PINNED_REV:0:7}, so it may be older than the pin. Pull or rebase it."
  fi

  local added=() gone=() dir name
  for dir in "$CHECKOUT"/skills/*/; do
    name=$(basename "$dir")
    [[ " $SKILLS " == *" $name "* ]] || added+=("$name")
  done
  for dir in "$CHECKOUT"/apps/*/; do
    name=$(basename "$dir")
    jq -e 'has("claude") or has("pi")' "$dir/package.json" >/dev/null 2>&1 || continue
    [[ " $PLUGINS " == *" $name "* ]] || added+=("$name")
  done
  for name in $SKILLS; do [ -d "$CHECKOUT/skills/$name" ] || gone+=("$name"); done
  for name in $PLUGINS; do [ -d "$CHECKOUT/apps/$name" ] || gone+=("$name"); done
  [ ${#added[@]} -eq 0 ] || echo "agents live: new in the checkout, loaded after a switch: ${added[*]}."
  [ ${#gone[@]} -eq 0 ] || echo "agents live: gone from the checkout, still linked until a switch: ${gone[*]}."
}

case "${1:-}" in
  build) build ;;
  check) check ;;
  hook)
    out=$(check)
    [ -z "$out" ] || jq -n --arg m "$out" '{systemMessage: $m}'
    ;;
  *)
    echo "usage: agents-live build|check|hook" >&2
    exit 2
    ;;
esac
