#!/usr/bin/env bash
set -euo pipefail

# claude-wt: manage Claude Code's worktrees under <repo>/.claude/worktrees/.
#
# Verbs:
#   list                       Show all Claude worktrees with state.
#   clean [--dry-run] [<name>] Remove safely-removable worktrees.
#                              No name: clean every safe one. With name: clean
#                              that one.
#   apply [--dry-run] [<name>] Rebase the worktree's branch onto
#                              origin/<default>, remove the worktree, leave the
#                              branch in the main checkout.

usage() {
    cat >&2 <<'EOF'
Usage:
  claude-wt list
  claude-wt clean [--dry-run] [<name>]
  claude-wt apply [--dry-run] [<name>]
EOF
}

die()  { printf 'claude-wt: %s\n' "$*" >&2; exit 1; }
info() { printf 'claude-wt: %s\n' "$*" >&2; }

# --- discovery --------------------------------------------------------------

find_main_worktree() {
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
        || die "not inside a git repository"
    git worktree list --porcelain | awk '/^worktree / {print $2; exit}'
}

find_default_branch() {
    local main="$1" ref b
    if ref=$(git -C "$main" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null); then
        echo "${ref#refs/remotes/origin/}"
        return
    fi
    for b in main master; do
        if git -C "$main" rev-parse --verify --quiet "refs/heads/$b" >/dev/null 2>&1; then
            echo "$b"; return
        fi
    done
    die "could not determine default branch (no origin/HEAD, no main, no master)"
}

declare -A REG_BRANCH REG_LOCKED
build_registration_maps() {
    local main="$1" line p=""
    while IFS= read -r line; do
        case "$line" in
            "worktree "*) p="${line#worktree }" ;;
            "branch "*)   [[ -n "$p" ]] && REG_BRANCH["$p"]="${line#branch }" ;;
            "detached")   [[ -n "$p" ]] && REG_BRANCH["$p"]="" ;;
            "locked"*)    [[ -n "$p" ]] && REG_LOCKED["$p"]=1 ;;
            "")           p="" ;;
        esac
    done < <(git -C "$main" worktree list --porcelain)
}

# --- helpers ----------------------------------------------------------------

format_age() {
    local s=$1
    if   (( s < 60 ));      then echo "${s}s"
    elif (( s < 3600 ));    then echo "$((s/60))m"
    elif (( s < 86400 ));   then echo "$((s/3600))h"
    elif (( s < 2592000 )); then echo "$((s/86400))d"
    else                         echo "$((s/2592000))mo"
    fi
}

format_vs() {
    local ahead="$1" behind="$2"
    if [[ "$ahead" == "-" ]]; then echo "-"; return; fi
    printf '+%s -%s' "$ahead" "$behind"
}

dir_has_files() {
    [[ -n "$(find "$1" -type f -print -quit 2>/dev/null)" ]]
}

# --- core data --------------------------------------------------------------

# Emit one TSV row per directory under <main>/.claude/worktrees/.
# Fields: name path registered branch state ahead behind locked age_seconds safe_clean
gather_worktrees() {
    local main="$1" default_branch="$2"
    local wt_dir="$main/.claude/worktrees"
    [[ -d "$wt_dir" ]] || return 0

    local now
    now=$(date +%s)

    local path name reg branch state ahead behind locked age_s safe_clean
    local porcelain ab mt
    for path in "$wt_dir"/*/; do
        [[ -d "$path" ]] || continue
        path="${path%/}"
        name="${path##*/}"

        reg=0
        branch=""
        if [[ -n "${REG_BRANCH[$path]+set}" ]]; then
            reg=1
            branch="${REG_BRANCH[$path]#refs/heads/}"
        fi

        locked=0
        if [[ -n "${REG_LOCKED[$path]+set}" ]]; then
            locked=1
        fi

        ahead="-"
        behind="-"
        if (( reg == 1 )); then
            porcelain=$(git -C "$path" status --porcelain 2>/dev/null || true)
            if [[ -z "$porcelain" ]]; then
                state="clean"
            elif grep -qvE '^\?\?' <<<"$porcelain"; then
                state="dirty"
            else
                state="untracked"
            fi

            if git -C "$path" rev-parse --verify --quiet "refs/remotes/origin/${default_branch}" >/dev/null 2>&1; then
                if ab=$(git -C "$path" rev-list --left-right --count "refs/remotes/origin/${default_branch}...HEAD" 2>/dev/null); then
                    behind=$(awk '{print $1}' <<<"$ab")
                    ahead=$(awk  '{print $2}' <<<"$ab")
                fi
            elif git -C "$path" rev-parse --verify --quiet "refs/heads/${default_branch}" >/dev/null 2>&1; then
                if ab=$(git -C "$path" rev-list --left-right --count "refs/heads/${default_branch}...HEAD" 2>/dev/null); then
                    behind=$(awk '{print $1}' <<<"$ab")
                    ahead=$(awk  '{print $2}' <<<"$ab")
                fi
            fi

            if [[ "$state" == "clean" && "$ahead" == "0" && "$locked" == "0" ]]; then
                safe_clean=1
            else
                safe_clean=0
            fi
        else
            state="orphan"
            if dir_has_files "$path"; then
                safe_clean=0
            else
                safe_clean=1
            fi
        fi

        mt=$(stat -c %Y "$path" 2>/dev/null || echo "$now")
        age_s=$(( now - mt ))

        # Use ASCII Unit Separator (\x1f) so empty fields aren't collapsed by
        # bash's `read` (which collapses runs of whitespace IFS chars like \t).
        printf '%s\x1f%s\x1f%d\x1f%s\x1f%s\x1f%s\x1f%s\x1f%d\x1f%d\x1f%d\n' \
            "$name" "$path" "$reg" "$branch" "$state" "$ahead" "$behind" "$locked" "$age_s" "$safe_clean"
    done
}

# --- formatting -------------------------------------------------------------

# stdin: gather rows (\x1f-separated fields); stdout: 5-column display TSV.
format_display() {
    local name path reg branch state ahead behind locked age_s safe_clean
    while IFS=$'\x1f' read -r name path reg branch state ahead behind locked age_s safe_clean; do
        local branch_disp vs_disp state_disp age_disp

        if (( reg == 0 )); then
            branch_disp="(orphan)"
            vs_disp="-"
        elif [[ -z "$branch" ]]; then
            branch_disp="(detached)"
            vs_disp=$(format_vs "$ahead" "$behind")
        else
            branch_disp="$branch"
            vs_disp=$(format_vs "$ahead" "$behind")
        fi

        if (( locked == 1 )); then
            state_disp="locked"
        else
            state_disp="$state"
        fi

        age_disp=$(format_age "$age_s")
        printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$branch_disp" "$state_disp" "$vs_disp" "$age_disp"
    done
    # quiet shellcheck about unused: path/safe_clean are read but not used here
    : "${path:-}" "${safe_clean:-}"
}

colorize_if_tty() {
    if [[ ! -t 1 ]]; then cat; return; fi
    local R=$'\033[0m'
    local G=$'\033[32m'
    local Y=$'\033[33m'
    local D=$'\033[2m'
    local C=$'\033[36m'
    local M=$'\033[35m'
    sed -E \
        -e "s/\\bclean\\b/${G}clean${R}/g" \
        -e "s/\\b(dirty|untracked|locked)\\b/${Y}\\1${R}/g" \
        -e "s/\\((orphan|detached)\\)/${D}(\\1)${R}/g" \
        -e "s/(\\+[0-9]+)/${C}\\1${R}/g" \
        -e "s/(-[0-9]+)/${M}\\1${R}/g"
}

print_table() {
    {
        printf 'NAME\tBRANCH\tSTATE\tvs main\tAGE\n'
        cat
    } | column -t -s $'\t' | colorize_if_tty
}

# --- verbs ------------------------------------------------------------------

cmd_list() {
    local rows
    rows=$(gather_worktrees "$MAIN_WT" "$DEFAULT_BRANCH")
    if [[ -z "$rows" ]]; then
        info "no Claude worktrees under $MAIN_WT/.claude/worktrees"
        return 0
    fi
    printf '%s\n' "$rows" | format_display | print_table
}

cmd_clean() {
    local dry_run=0 target=""
    while (( $# > 0 )); do
        case "$1" in
            --dry-run) dry_run=1; shift ;;
            -*)        die "unknown flag: $1" ;;
            *)         target="$1"; shift ;;
        esac
    done

    local rows
    rows=$(gather_worktrees "$MAIN_WT" "$DEFAULT_BRANCH")
    if [[ -z "$rows" ]]; then
        info "no Claude worktrees under $MAIN_WT/.claude/worktrees"
        return 0
    fi

    local removed=0 skipped=0 matched=0
    local name path reg branch state ahead behind locked age_s safe_clean
    while IFS=$'\x1f' read -r name path reg branch state ahead behind locked age_s safe_clean; do
        if [[ -n "$target" && "$name" != "$target" ]]; then
            continue
        fi
        matched=1

        if (( safe_clean == 0 )); then
            if [[ -n "$target" ]]; then
                if (( reg == 1 )); then
                    if (( locked == 1 )); then
                        die "'$name' is locked. Run: git -C '$MAIN_WT' worktree unlock '$path'"
                    elif [[ "$state" != "clean" ]]; then
                        die "'$name' has uncommitted changes ($state); commit/stash inside the worktree first"
                    else
                        die "'$name' has $ahead commit(s) ahead of origin/$DEFAULT_BRANCH; run 'claude-wt apply $name' to keep the work"
                    fi
                else
                    die "'$name' is an orphan with files inside; inspect $path manually"
                fi
            else
                (( skipped += 1 ))
                continue
            fi
        fi

        if (( reg == 1 )); then
            if (( dry_run == 1 )); then
                info "would remove (registered) $name"
            else
                git -C "$MAIN_WT" worktree remove "$path"
                info "removed (registered) $name"
            fi
        else
            if (( dry_run == 1 )); then
                info "would remove (orphan)     $name"
            else
                rm -rf -- "$path"
                info "removed (orphan)     $name"
            fi
        fi
        (( removed += 1 ))
    done <<<"$rows"

    if [[ -n "$target" && "$matched" -eq 0 ]]; then
        die "no worktree named '$target'"
    fi

    if (( dry_run == 0 )); then
        git -C "$MAIN_WT" worktree prune
    fi

    if [[ -z "$target" ]]; then
        if (( dry_run == 1 )); then
            info "would remove $removed, $skipped left"
        else
            info "removed $removed, $skipped left"
        fi
    fi

    # quiet shellcheck about unused locals read above
    : "${branch:-}" "${behind:-}" "${age_s:-}"
}

cmd_apply() {
    local dry_run=0 target=""
    while (( $# > 0 )); do
        case "$1" in
            --dry-run) dry_run=1; shift ;;
            -*)        die "unknown flag: $1" ;;
            *)         target="$1"; shift ;;
        esac
    done

    local rows
    rows=$(gather_worktrees "$MAIN_WT" "$DEFAULT_BRANCH")
    [[ -n "$rows" ]] || die "no Claude worktrees under $MAIN_WT/.claude/worktrees"

    if [[ -z "$target" ]]; then
        local choices
        choices=$(printf '%s\n' "$rows" \
            | while IFS=$'\x1f' read -r n p r b s a beh lk age sc; do
                if (( r == 1 )) && [[ -n "$b" && "${b#refs/heads/}" != "$DEFAULT_BRANCH" ]]; then
                    printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$n" "${b#refs/heads/}" "$s" \
                        "$(format_vs "$a" "$beh")" "$(format_age "$age")"
                fi
                : "$p" "$lk" "$sc"
            done)
        if [[ -z "$choices" ]]; then
            die "no worktrees with applyable branches"
        fi
        local picked
        picked=$({ printf 'NAME\tBRANCH\tSTATE\tvs main\tAGE\n'; printf '%s\n' "$choices"; } \
            | column -t -s $'\t' \
            | fzf --prompt="apply > " --header-lines=1 --layout=reverse --height=40%) \
            || die "no selection"
        target=$(awk '{print $1}' <<<"$picked")
    fi

    local found=""
    local line
    while IFS= read -r line; do
        local n
        n=$(awk -F$'\x1f' '{print $1}' <<<"$line")
        if [[ "$n" == "$target" ]]; then
            found="$line"
            break
        fi
    done <<<"$rows"

    [[ -n "$found" ]] || die "no worktree named '$target'"

    local name path reg branch state ahead behind locked age_s safe_clean
    IFS=$'\x1f' read -r name path reg branch state ahead behind locked age_s safe_clean <<<"$found"

    (( reg == 1 ))                       || die "'$name' is an orphan — nothing to apply, run 'clean' instead"
    [[ -n "$branch" ]]                   || die "'$name' is detached (no branch to keep)"
    [[ "$branch" != "$DEFAULT_BRANCH" ]] || die "'$name' is on the default branch — nothing to apply"
    [[ "$state" == "clean" ]]            || die "'$name' has uncommitted changes ($state); commit or stash inside the worktree first"
    [[ "$ahead" != "-" && "$ahead" != "0" ]] \
        || die "'$name' has no commits ahead of origin/$DEFAULT_BRANCH; run 'clean'"
    (( locked == 0 ))                    || die "'$name' is locked. Run: git -C '$MAIN_WT' worktree unlock '$path'"

    if (( dry_run == 1 )); then
        info "would rebase $name ($branch) onto origin/$DEFAULT_BRANCH and remove worktree"
        return 0
    fi

    local target_ref=""
    if git -C "$path" remote get-url origin >/dev/null 2>&1 \
        && git -C "$path" fetch origin "$DEFAULT_BRANCH" 2>/dev/null \
        && git -C "$path" rev-parse --verify --quiet "refs/remotes/origin/$DEFAULT_BRANCH" >/dev/null; then
        target_ref="origin/$DEFAULT_BRANCH"
    elif git -C "$path" rev-parse --verify --quiet "refs/heads/$DEFAULT_BRANCH" >/dev/null 2>&1; then
        target_ref="$DEFAULT_BRANCH"
    else
        die "no rebase target: neither origin/$DEFAULT_BRANCH nor local $DEFAULT_BRANCH exists"
    fi

    info "rebasing $branch onto $target_ref"
    if ! git -C "$path" rebase "$target_ref"; then
        git -C "$path" rebase --abort 2>/dev/null || true
        die "rebase conflict; resolve in $path"
    fi

    info "removing worktree $path"
    git -C "$MAIN_WT" worktree remove "$path"

    info "done. Branch '$branch' is now available in the main checkout."

    : "${behind:-}" "${age_s:-}" "${safe_clean:-}"
}

# --- main -------------------------------------------------------------------

if (( $# == 0 )); then
    usage
    exit 1
fi

verb="$1"; shift
MAIN_WT=$(find_main_worktree)
DEFAULT_BRANCH=$(find_default_branch "$MAIN_WT")
build_registration_maps "$MAIN_WT"

case "$verb" in
    list)            cmd_list "$@" ;;
    clean)           cmd_clean "$@" ;;
    apply)           cmd_apply "$@" ;;
    -h|--help|help)  usage ;;
    *)               usage; exit 1 ;;
esac
