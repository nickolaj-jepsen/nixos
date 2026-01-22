#!/usr/bin/env bash
set -euo pipefail

PORT=$1
if [ -z "$PORT" ]; then
    echo "Usage: port-kill <port>"
    exit 1
fi

# lsof returns exit code 1 if no files found
PID=$(lsof -t -i:"$PORT" || true)

if [ -z "$PID" ]; then
    echo "No process found on port $PORT"
    exit 1
fi

COMMAND=$(ps -p "$PID" -o comm=)
echo "Process '$COMMAND' (PID $PID) is using port $PORT."
read -p "Kill? [y/N] " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    kill "$PID"
    echo "Killed."
fi
