#!/usr/bin/env bash
set -euo pipefail

PORT=${1:-}
if [ -z "$PORT" ]; then
    echo "Usage: port-kill <port>"
    exit 1
fi

# Listeners only (a bare -i:PORT also matches connected clients); lsof exits 1 on no match.
mapfile -t PIDS < <(lsof -t -iTCP:"$PORT" -sTCP:LISTEN || true)

if [ ${#PIDS[@]} -eq 0 ]; then
    echo "No process listening on port $PORT"
    exit 1
fi

echo "Listening on port $PORT:"
ps -o pid=,comm= -p "$(IFS=,; echo "${PIDS[*]}")"
read -p "Kill? [y/N] " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    kill "${PIDS[@]}"
    echo "Killed."
fi
