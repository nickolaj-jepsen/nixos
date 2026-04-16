#!/usr/bin/env bash
# shellcheck disable=SC2016  # single-quoted strings deliberately defer expansion to fzf/bash -c
set -euo pipefail

# Browse open PRs with fzf.
# Any extra args are forwarded to gh (e.g. `ghpr -R owner/repo`).

if ! gh auth status &>/dev/null; then
    echo "gh is not authenticated. Run: gh auth login" >&2
    exit 1
fi

# Re-export forwarded gh args as a single string so child shells (fzf
# preview / execute / reload bindings) can pick them up via $GHPR_ARGS.
export GHPR_ARGS="$*"

list_prs() {
    # shellcheck disable=SC2086,SC2016
    gh pr list $GHPR_ARGS --limit 100 \
        --json number,title,author,headRefName,statusCheckRollup \
        --jq '
            .[] |
            ([.statusCheckRollup[]? | (.conclusion // .state)]) as $s |
            (if ($s | length) == 0 then "-"
             elif any($s[]; . == "FAILURE" or . == "ERROR" or . == "TIMED_OUT" or . == "CANCELLED" or . == "ACTION_REQUIRED") then "x"
             elif any($s[]; . == "PENDING" or . == "IN_PROGRESS" or . == "QUEUED" or . == "WAITING" or . == "EXPECTED") then "?"
             else "+" end) as $status |
            "#\(.number)\t\($status)\t\(.title)\t@\(.author.login)\t[\(.headRefName)]"
        ' \
        | column -t -s $'\t'
}
export -f list_prs

# Helper: strip the leading "#" from the first field of the selected line and
# run a gh subcommand. Accepts the action as remaining args, e.g.
#   _ghpr_run "#123" view
#   _ghpr_run "#123" merge --rebase --auto
_ghpr_run() {
    local num=${1#\#}
    shift
    # shellcheck disable=SC2086
    gh pr "$@" "$num" $GHPR_ARGS
}
export -f _ghpr_run

# Single quotes are intentional below: $1 must be expanded by the inner
# `bash -c`, not by the outer shell (the outer shell has no positional args
# at that point — fzf substitutes {1} into the command before bash runs it).
# shellcheck disable=SC2016
selected=$(list_prs | SHELL=bash fzf \
    --prompt="PR > " \
    --header=$'enter: view  C-r: merge --rebase --auto  C-o: open in browser  C-d: diff  C-x: close  C-l: reload' \
    --layout=reverse \
    --preview 'bash -c "_ghpr_run \"\$1\" view; echo; echo \"--- Checks ---\"; _ghpr_run \"\$1\" checks 2>/dev/null || true" _ {1}' \
    --preview-window=right:60%,wrap \
    --bind 'ctrl-r:execute(bash -c "_ghpr_run \"\$1\" merge --rebase --auto" _ {1})+reload(list_prs)' \
    --bind 'ctrl-o:execute-silent(bash -c "_ghpr_run \"\$1\" view --web" _ {1})' \
    --bind 'ctrl-d:execute(bash -c "_ghpr_run \"\$1\" diff | less -R" _ {1})' \
    --bind 'ctrl-x:execute(bash -c "_ghpr_run \"\$1\" close" _ {1})+reload(list_prs)' \
    --bind 'ctrl-l:reload(list_prs)')

if [ -n "$selected" ]; then
    _ghpr_run "$(echo "$selected" | awk '{print $1}')" view
fi
