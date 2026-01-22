#!/usr/bin/env bash
set -euo pipefail

if ! command -v kubectl &> /dev/null; then
    echo "kubectl not found"
    exit 1
fi

CONTEXTS=$(kubectl config get-contexts -o name)

if [ -z "$CONTEXTS" ]; then
    echo "No kubernetes contexts found"
    exit 1
fi

SELECTED=$(echo "$CONTEXTS" | fzf --prompt="Kube Context > " --height=20% --layout=reverse)

if [ -n "$SELECTED" ]; then
    kubectl config use-context "$SELECTED"
    echo "Switched to context: $SELECTED"
fi
