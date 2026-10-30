#!/usr/bin/env bash
# PreToolUse gate for Skill: a plugin or claude.ai skill (`<namespace>:<name>`)
# yields to a local skill of the same name. Plugin skills can't be switched off
# one by one in settings, so a copy like ao-skills:grill-me is refused here.
# Exit 2 blocks the call and shows stderr to the model.
set -euo pipefail

skill=$(jq -r '.tool_input.skill // empty')
case "$skill" in *:*) ;; *) exit 0 ;; esac
name=${skill#*:}
grep -qxF -- "$name" "$LOCAL_SKILLS" || exit 0

printf 'The local skill "%s" takes priority over "%s"; call the Skill tool with "%s" instead.\n' \
  "$name" "$skill" "$name" >&2
exit 2
