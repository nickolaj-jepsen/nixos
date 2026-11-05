#!/usr/bin/env bash
# Run one program against this repo's home-manager config without switching:
# the host's activation runs inside a bubblewrap overlay of $HOME, then the
# program starts in that same sandbox. Every config file is the new one, and
# nothing written to $HOME (by activation or by the program) survives the run.
set -euo pipefail

if [ $# -lt 2 ]; then
    echo "Usage: try.sh <home-manager generation> <program> [args...]" >&2
    exit 2
fi

gen=$1
program=$2
shift 2

if [ "$(uname -s)" != Linux ]; then
    echo "just try needs bubblewrap, so it is Linux-only; switch on darwin as usual." >&2
    exit 1
fi

if [ ! -x "$gen/activate" ]; then
    echo "Not a home-manager generation: $gen" >&2
    exit 1
fi

# The new config's own binary, so a version bump is part of what is tested; the
# NixOS half is not in this generation, so a system package comes from PATH.
if [ -x "$gen/home-path/bin/$program" ]; then
    bin=$gen/home-path/bin/$program
elif bin=$(command -v "$program"); then
    echo "note: $program is not a home-manager package here; running $bin" >&2
else
    echo "No '$program' in $gen/home-path/bin and not on PATH." >&2
    echo "Names to try: ls $gen/home-path/bin | grep -i ${program:0:3}" >&2
    exit 1
fi

if command -v bwrap >/dev/null 2>&1; then
    bwrap=bwrap
else
    bwrap=$(nix build --no-link --print-out-paths nixpkgs#bubblewrap)/bin/bwrap
fi

exec "$bwrap" \
    --dev-bind / / \
    --overlay-src "$HOME" --tmp-overlay "$HOME" \
    --setenv TRY_RUNTIME_DIR "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
    --setenv TRY_BUS "${DBUS_SESSION_BUS_ADDRESS:-}" \
    bash -c '
        set -e
        log=$(mktemp)
        # Activation reloads user units and loads dconf over the session bus;
        # with neither reachable it skips both instead of touching the live
        # session, which is also why HOME can stay the real path.
        export XDG_RUNTIME_DIR=$(mktemp -d)
        unset DBUS_SESSION_BUS_ADDRESS
        if ! "$0/activate" >"$log" 2>&1; then
            cat "$log" >&2
            echo "Activation failed; nothing was applied to $HOME." >&2
            exit 1
        fi
        rm -f "$log"
        export PATH="$0/home-path/bin:$PATH"
        export XDG_RUNTIME_DIR=$TRY_RUNTIME_DIR
        if [ -n "$TRY_BUS" ]; then export DBUS_SESSION_BUS_ADDRESS=$TRY_BUS; fi
        exec "$@"
    ' "$gen" "$bin" "$@"
