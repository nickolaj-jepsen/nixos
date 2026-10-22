#!/usr/bin/env -S bash -euo pipefail
# Lays the Claude Code mods' API types into their gitignored .claude-plugin/types/, for
# editor types and `tsc -p`. Only an interactive session lays them, so this runs one on a
# throwaway pty until it has.

cd "$(dirname "$0")/.."

mods=(modules/programs/claude-code/mods/*/.claude-plugin)
args=()
for m in "${mods[@]}"; do
    rm -rf "$m/types"
    args+=(--plugin-dir "$(realpath "$m/..")")
done

# The store copies in CLAUDE_CODE_PLUGIN_DIRS would otherwise load beside the folders
# under the same names.
if [ "$(uname)" = Darwin ]; then
    CLAUDE_CODE_PLUGIN_DIRS= script -q /dev/null claude "${args[@]}" </dev/null >/dev/null 2>&1 &
else
    CLAUDE_CODE_PLUGIN_DIRS= script -qec "claude ${args[*]@Q}" /dev/null </dev/null >/dev/null 2>&1 &
fi
pid=$!
trap 'kill $pid 2>/dev/null || true' EXIT

for _ in $(seq 60); do
    laid=0
    for m in "${mods[@]}"; do
        [ -f "$m/types/tsconfig.json" ] && [ -f "$m/types/claude-code/index.d.ts" ] && laid=$((laid + 1))
    done
    if [ "$laid" = "${#mods[@]}" ]; then
        sleep 1
        echo "Laid types for $laid mods; restart the editor's TypeScript server to pick them up"
        exit 0
    fi
    sleep 1
done

echo "Timed out waiting for Claude Code to lay the mod types" >&2
exit 1
