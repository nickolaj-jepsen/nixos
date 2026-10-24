#!/usr/bin/env bash
set -euo pipefail

# wt: manage git worktrees. Worktrees live in <root>/<repo>/<name> (root: see
# WORKTREE_ROOT below), never inside the checkout itself. Discovery stays
# git-driven (every worktree registered to the repo, wherever it lives), with
# <root>/<repo>/ and the legacy <repo>/.claude/worktrees/ scanned on top to
# surface orphans git no longer tracks.
#
# `wt guard` is the same layout from the other side: agent hooks call it to
# refuse `git worktree add` that would escape the root.

usage() {
    cat >&2 <<'EOF'
Usage:
  wt list                        Show every worktree with state (incl. a (main) row).
  wt create <name> [<base>]      Create <root>/<repo>/<name> on a new branch <name> off
                                 <base> (default: <default>), copying the gitignored paths
                                 the repo's .worktreeinclude lists; prints its path.
  wt cd [<name>]                 Print a worktree's path (fzf picker if no name).
  wt clean [--dry-run] [--force] [<name>]
                                 Remove safely-removable worktrees and their branches: clean,
                                 unlocked, every commit already on <default> (rebased or
                                 cherry-picked counts), no other process inside. No name
                                 cleans every safe one (never main, never one parked on
                                 <default>). --force names one worktree and drops its
                                 uncommitted or unmerged work.
  wt apply [--dry-run] [<name>]  Rebase onto <default>, remove the worktree, fast-forward
                                 <default>, delete the branch. Needs main on clean <default>.
  wt diff [<name>]               Review the diff (committed + uncommitted) vs <default>.
  wt smerge [<name>]             Open the worktree in Sublime Merge.
  wt code [<name>]               Open the worktree in VS Code.
  wt migrate [--dry-run]         Move this repo's worktrees that live outside the root into
                                 <root>/<repo>/.
  wt names                       Print every worktree name, one per line (shell completions).
  wt status [<name>]             Machine-readable: one \x1f-separated row per worktree
                                 (name path registered branch state ahead behind locked
                                 age_seconds safe_clean is_main default_branch). Agent hooks
                                 read this instead of `wt list`.
  wt guard <command>             Exit 1 with a reason when <command> runs `git worktree add`
                                 outside the root, else exit 0. Agent hooks call this.
EOF
}

die()  { printf 'wt: %s\n' "$*" >&2; exit 1; }
info() { printf 'wt: %s\n' "$*" >&2; }

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

# --- layout -----------------------------------------------------------------

# One folder per repo, one dir per worktree. Outside the checkout on purpose: a
# repo never contains its own siblings, so rg/builds/editors don't walk them.
WORKTREE_ROOT="${WT_WORKTREE_ROOT:-$HOME/worktrees}"

# Directory name of a repo: the checkout holding the shared .git, which is the
# same for every worktree of it, so creating from a worktree still lands right.
repo_key() {
    local common
    common=$(git -C "${1:-.}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
    common="${common%/.git}"
    basename "$common"
}

worktree_dir() {
    local key
    key=$(repo_key "$1") || return 1
    printf '%s/%s\n' "$WORKTREE_ROOT" "$key"
}

# Lexical normalisation of a path that need not exist yet: no symlink resolution.
normpath() {
    local p="$1" part
    local -a parts=()
    [[ "$p" == /* ]] || p="$PWD/$p"
    local IFS=/
    for part in $p; do
        case "$part" in
            ''|.) ;;
            ..) if (( ${#parts[@]} )); then unset 'parts[-1]'; fi ;;
            *) parts+=("$part") ;;
        esac
    done
    printf '/%s\n' "$(IFS=/; printf '%s' "${parts[*]}")"
}

# True when <path> (relative to PWD) stays inside <dir>/.
in_worktree_root() {
    local abs
    [[ -n "$2" ]] || return 1
    # An unexpanded variable could resolve anywhere, so refuse instead of guessing.
    [[ "$2" == *'$'* ]] && return 1
    abs=$(normpath "$2")
    [[ "$abs" == "$(normpath "$1")"/* ]]
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

# Parent of <pid>, or nothing once it is gone.
parent_of() {
    local stat
    local -a rest
    if [[ -r /proc/$1/stat ]]; then
        stat=$(<"/proc/$1/stat")
        # Fields after `comm`, which may hold spaces: state ppid …
        read -ra rest <<<"${stat##*) }"
        printf '%s\n' "${rest[1]}"
    else
        ps -o ppid= -p "$1" 2>/dev/null | tr -d ' ' || true
    fi
}

# "pid<TAB>cwd" of every process this user can see, read once per gather from /
# so the scan never counts itself. wt's ancestors and whatever its caller started
# are not users: the caller's shell sits in the worktree by construction, and so
# do a pipeline's other commands and a pi session's LSP and MCP servers.
PROC_CWDS="" PROC_CWDS_READ=0 OUR_PIDS="" CALLER=""
read_proc_cwds() {
    (( PROC_CWDS_READ == 0 )) || return 0
    PROC_CWDS_READ=1
    local pid=$BASHPID
    CALLER=$(parent_of "$$")
    while [[ -n "$pid" ]] && (( pid > 1 )); do
        OUR_PIDS+=" $pid "
        pid=$(parent_of "$pid")
    done
    if [[ -d /proc/self ]]; then
        PROC_CWDS=$(cd / && find /proc/[0-9]*/cwd -maxdepth 0 -printf '%h\t%l\n' 2>/dev/null \
            | sed 's|^/proc/||') || true
    else
        PROC_CWDS=$(cd / && lsof -a -d cwd -Fn 2>/dev/null \
            | awk '/^p/ { pid = substr($0, 2) } /^n/ { print pid "\t" substr($0, 2) }') || true
    fi
}

# Whether <pid> descends from wt's caller; an orphaned wt (caller init) has none.
callers_own() {
    local pid=$1
    [[ -n "$CALLER" ]] && (( CALLER > 1 )) || return 1
    while [[ -n "$pid" ]] && (( pid > 1 )); do
        [[ "$pid" == "$CALLER" ]] && return 0
        pid=$(parent_of "$pid")
    done
    return 1
}

# Print the pid of a process, not wt's own, whose cwd is in <path>; fail when there is none.
in_use() {
    local root pid
    root=$(realpath "$1" 2>/dev/null) || root="$1"
    read_proc_cwds
    while IFS= read -r pid; do
        [[ -n "$(parent_of "$pid")" ]] || continue # gone since the scan
        callers_own "$pid" && continue
        printf '%s\n' "$pid"
        return 0
    done < <(awk -F'\t' -v root="$root" -v ours="$OUR_PIDS" \
        'index(ours, " " $1 " ") == 0 && ($2 == root || index($2, root "/") == 1) { print $1 }' <<<"$PROC_CWDS")
    return 1
}

# Commits on HEAD whose change is not on <upstream> yet: unlike `ahead`, a branch
# that was rebased or cherry-picked onto it counts as landed.
unlanded() {
    local out
    out=$(git -C "$1" cherry "$2" HEAD 2>/dev/null) || { echo "-"; return; }
    grep -c '^+' <<<"$out" || true
}

# 'apply' fast-forwards the default branch in the main checkout, so that checkout
# must be parked on a clean default first. Fail fast with an actionable message.
require_main_on_clean_default() {
    local cur
    cur=$(git -C "$MAIN_WT" symbolic-ref --short --quiet HEAD 2>/dev/null) \
        || die "main checkout is in detached HEAD; checkout $DEFAULT_BRANCH first"
    [[ "$cur" == "$DEFAULT_BRANCH" ]] \
        || die "main checkout is on '$cur', not '$DEFAULT_BRANCH'; park it on '$DEFAULT_BRANCH' first"
    [[ -z "$(git -C "$MAIN_WT" status --porcelain 2>/dev/null)" ]] \
        || die "main checkout has uncommitted changes; commit or stash in $MAIN_WT first"
}

# --- core data --------------------------------------------------------------

# Emit one TSV row per worktree: every registered worktree (main first), plus
# orphan dirs under the root that git no longer tracks.
# Fields: name path registered branch state ahead behind locked age_seconds safe_clean is_main
# safe_clean: what `wt clean` removes unasked — clean, unlocked, nothing unlanded
# ahead, and nobody else's cwd inside (see read_proc_cwds).
# 'name' is the path basename; basenames shared across worktrees are
# disambiguated to <parent>/<base> on the colliding rows only.
gather_worktrees() {
    local main="$1" default_branch="$2"
    local wt_dir scan_dir
    wt_dir=$(worktree_dir "$main")

    # Path set: every registered worktree (main first so it heads the listing),
    # then orphan dirs under the root and under the pre-root .claude/worktrees/
    # git doesn't know about (still surfaced so `wt clean` can reap them).
    local -A seen=()
    local -a paths=()
    local p
    paths+=("$main"); seen["$main"]=1
    for p in "${!REG_BRANCH[@]}"; do
        [[ -n "${seen[$p]+s}" ]] && continue
        paths+=("$p"); seen["$p"]=1
    done
    for scan_dir in "$wt_dir" "$main/.claude/worktrees"; do
        [[ -d "$scan_dir" ]] || continue
        for p in "$scan_dir"/*/; do
            [[ -d "$p" ]] || continue
            p="${p%/}"
            [[ -n "${seen[$p]+s}" ]] && continue
            paths+=("$p"); seen["$p"]=1
        done
    done

    # Tally basenames so colliding ones can be disambiguated below.
    local -A base_count=()
    local bn
    for p in "${paths[@]}"; do
        bn="${p##*/}"
        base_count["$bn"]=$(( ${base_count["$bn"]:-0} + 1 ))
    done

    local now
    now=$(date +%s)

    local name reg branch state ahead behind locked age_s safe_clean is_main
    local porcelain ab mt parent upstream
    for p in "${paths[@]}"; do
        name="${p##*/}"
        if (( ${base_count["$name"]} > 1 )); then
            parent="${p%/*}"; parent="${parent##*/}"
            name="$parent/$name"
        fi

        is_main=0
        [[ "$p" == "$main" ]] && is_main=1

        reg=0
        branch=""
        if [[ -n "${REG_BRANCH[$p]+set}" ]]; then
            reg=1
            branch="${REG_BRANCH[$p]#refs/heads/}"
        fi

        locked=0
        if [[ -n "${REG_LOCKED[$p]+set}" ]]; then
            locked=1
        fi

        ahead="-"
        behind="-"
        if (( reg == 1 )); then
            porcelain=$(git -C "$p" status --porcelain 2>/dev/null || true)
            if [[ -z "$porcelain" ]]; then
                state="clean"
            elif grep -qvE '^\?\?' <<<"$porcelain"; then
                state="dirty"
            else
                state="untracked"
            fi

            upstream=""
            if git -C "$p" rev-parse --verify --quiet "refs/remotes/origin/${default_branch}" >/dev/null 2>&1; then
                upstream="refs/remotes/origin/${default_branch}"
            elif git -C "$p" rev-parse --verify --quiet "refs/heads/${default_branch}" >/dev/null 2>&1; then
                upstream="refs/heads/${default_branch}"
            fi
            if [[ -n "$upstream" ]] \
                && ab=$(git -C "$p" rev-list --left-right --count "${upstream}...HEAD" 2>/dev/null); then
                behind=$(awk '{print $1}' <<<"$ab")
                ahead=$(awk  '{print $2}' <<<"$ab")
            fi

            safe_clean=0
            # Cheapest test first: git cherry walks upstream back to the merge base.
            if [[ "$state" == "clean" && "$locked" == "0" && "$is_main" == "0" ]] \
                && { [[ "$ahead" == "0" ]] || [[ "$ahead" != "-" && "$(unlanded "$p" "$upstream")" == "0" ]]; } \
                && ! in_use "$p" >/dev/null; then
                safe_clean=1
            fi
        else
            state="orphan"
            if dir_has_files "$p"; then
                safe_clean=0
            else
                safe_clean=1
            fi
        fi

        mt=$(stat -c %Y "$p" 2>/dev/null || echo "$now")
        age_s=$(( now - mt ))

        # Use ASCII Unit Separator (\x1f) so empty fields aren't collapsed by
        # bash's `read` (which collapses runs of whitespace IFS chars like \t).
        printf '%s\x1f%s\x1f%d\x1f%s\x1f%s\x1f%s\x1f%s\x1f%d\x1f%d\x1f%d\x1f%d\n' \
            "$name" "$p" "$reg" "$branch" "$state" "$ahead" "$behind" "$locked" "$age_s" "$safe_clean" "$is_main"
    done
}

# --- formatting -------------------------------------------------------------

# stdin: gather rows (\x1f-separated fields); stdout: 5-column display TSV.
format_display() {
    local name path reg branch state ahead behind locked age_s safe_clean is_main
    while IFS=$'\x1f' read -r name path reg branch state ahead behind locked age_s safe_clean is_main; do
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

        # The main checkout is the comparison base, so its "vs main" is itself.
        if (( is_main == 1 )); then
            vs_disp="(main)"
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
        -e "s/\\((orphan|detached|main)\\)/${D}(\\1)${R}/g" \
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
        info "no worktrees"
        return 0
    fi
    printf '%s\n' "$rows" | format_display | print_table
}

# Machine-readable state: gather_worktrees' rows plus the default branch. Agents
# read this instead of `wt list`, and ask `wt apply --dry-run` whether a land would go.
cmd_status() {
    local target=""
    while (( $# > 0 )); do
        case "$1" in
            -*) die "unknown flag: $1" ;;
            *)  target="$1"; shift ;;
        esac
    done

    local rows
    rows=$(gather_worktrees "$MAIN_WT" "$DEFAULT_BRANCH")
    [[ -n "$rows" ]] || return 0

    local row name matched=0
    while IFS= read -r row; do
        name="${row%%$'\x1f'*}"
        if [[ -n "$target" && "$name" != "$target" ]]; then
            continue
        fi
        matched=1
        printf '%s\x1f%s\n' "$row" "$DEFAULT_BRANCH"
    done <<<"$rows"

    if [[ -n "$target" && "$matched" -eq 0 ]]; then
        die "no worktree named '$target'"
    fi
}

# Claude Code's own rule for a worktree's base, so a native Claude worktree and
# `wt create` start from the same commit: fetch origin/<default> when it is
# missing, or when the last fetch is over a day old (capped at 5s, so a slow
# remote never holds up a create). A failed fetch keeps whatever ref is there.
refresh_origin_default() {
    git -C "$MAIN_WT" remote get-url origin >/dev/null 2>&1 || return 0
    local common fetched
    common=$(git -C "$MAIN_WT" rev-parse --path-format=absolute --git-common-dir) || return 0
    if git -C "$MAIN_WT" rev-parse --verify --quiet "refs/remotes/origin/$DEFAULT_BRANCH" >/dev/null 2>&1; then
        fetched=$(stat -c %Y "$common/FETCH_HEAD" 2>/dev/null || echo 0)
        (( $(date +%s) - fetched > 86400 )) || return 0
        GIT_TERMINAL_PROMPT=0 timeout 5 git -C "$MAIN_WT" fetch --quiet origin "$DEFAULT_BRANCH" >&2 \
            || info "fetch of origin/$DEFAULT_BRANCH failed; basing on the local ref"
    else
        GIT_TERMINAL_PROMPT=0 git -C "$MAIN_WT" fetch --quiet origin "$DEFAULT_BRANCH" >&2 || true
    fi
}

# Claude Code's .worktreeinclude (.gitignore syntax): the gitignored files of the
# main checkout a fresh worktree needs too, copied with symlinks kept as links.
# A match that is tracked, or not gitignored, is git's to check out.
copy_worktreeinclude() {
    local dest="$1" include="$MAIN_WT/.worktreeinclude" rel
    [[ -f "$include" ]] || return 0
    while IFS= read -r -d '' rel; do
        rel="${rel%/}"
        git -C "$MAIN_WT" check-ignore -q -- "$rel" || continue
        mkdir -p "$(dirname "$dest/$rel")"
        cp -a -- "$MAIN_WT/$rel" "$dest/$rel" || info "could not copy $rel from .worktreeinclude"
    done < <(git -C "$MAIN_WT" ls-files -z --others --ignored --directory --exclude-from="$include")
}

cmd_create() {
    local name="" base=""
    while (( $# > 0 )); do
        case "$1" in
            -*) die "unknown flag: $1" ;;
            *)
                if [[ -z "$name" ]]; then
                    name="$1"
                elif [[ -z "$base" ]]; then
                    base="$1"
                else
                    die "too many arguments; usage: wt create <name> [<base>]"
                fi
                shift
                ;;
        esac
    done

    [[ -n "$name" ]] || { usage; exit 1; }

    # Branch keeps <name> verbatim (slashes allowed); the dir basename flattens
    # them so the worktree path stays one level under the root.
    local branch="$name"
    local dir_name="${name//\//-}"
    local wt_dir
    wt_dir=$(worktree_dir "$MAIN_WT") || die "not inside a git repository"
    local path="$wt_dir/$dir_name"

    [[ -e "$path" ]] && die "'$path' already exists"

    if git -C "$MAIN_WT" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null 2>&1; then
        die "branch '$branch' already exists; pick another name, or check it out yourself"
    fi

    # Base: explicit arg wins; otherwise the default branch, preferring the remote
    # tip (origin/<default>) so a fresh worktree starts from the integration point.
    local base_ref
    if [[ -n "$base" ]]; then
        git -C "$MAIN_WT" rev-parse --verify --quiet "$base^{commit}" >/dev/null 2>&1 \
            || die "base ref '$base' not found"
        base_ref="$base"
    elif refresh_origin_default \
        && git -C "$MAIN_WT" rev-parse --verify --quiet "refs/remotes/origin/$DEFAULT_BRANCH" >/dev/null 2>&1; then
        base_ref="origin/$DEFAULT_BRANCH"
    elif git -C "$MAIN_WT" rev-parse --verify --quiet "refs/heads/$DEFAULT_BRANCH" >/dev/null 2>&1; then
        base_ref="$DEFAULT_BRANCH"
    else
        die "no base: neither origin/$DEFAULT_BRANCH nor $DEFAULT_BRANCH exists"
    fi

    mkdir -p "$wt_dir"
    info "creating worktree '$dir_name' on new branch '$branch' off $base_ref"
    git -C "$MAIN_WT" worktree add -b "$branch" "$path" "$base_ref" >&2 \
        || die "git worktree add failed"
    copy_worktreeinclude "$path"

    # stdout is the path alone — for `cd (wt create ...)` and scripting.
    printf '%s\n' "$path"
}

cmd_cd() {
    local target=""
    while (( $# > 0 )); do
        case "$1" in
            -*) die "unknown flag: $1" ;;
            *)  target="$1"; shift ;;
        esac
    done

    local rows
    rows=$(gather_worktrees "$MAIN_WT" "$DEFAULT_BRANCH")
    [[ -n "$rows" ]] || die "no worktrees"

    # No name: pick any worktree (main included — cd is navigation, not mutation).
    if [[ -z "$target" ]]; then
        local choices
        choices=$(printf '%s\n' "$rows" \
            | while IFS=$'\x1f' read -r n p r b s a beh lk age sc im; do
                local b_disp
                if (( im == 1 )); then
                    b_disp="(main)"
                elif (( r == 0 )); then
                    b_disp="(orphan)"
                elif [[ -z "$b" ]]; then
                    b_disp="(detached)"
                else
                    b_disp="${b#refs/heads/}"
                fi
                local vs_disp
                if (( im == 1 )); then
                    vs_disp="(main)"
                else
                    vs_disp=$(format_vs "$a" "$beh")
                fi
                printf '%s\t%s\t%s\t%s\t%s\n' \
                    "$n" "$b_disp" "$s" \
                    "$vs_disp" "$(format_age "$age")"
                : "$p" "$lk" "$sc"
            done)
        local picked
        picked=$({ printf 'NAME\tBRANCH\tSTATE\tvs main\tAGE\n'; printf '%s\n' "$choices"; } \
            | column -t -s $'\t' \
            | fzf --prompt="cd > " --header-lines=1 --layout=reverse --height=40%) \
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

    local name path reg branch state ahead behind locked age_s safe_clean is_main
    IFS=$'\x1f' read -r name path reg branch state ahead behind locked age_s safe_clean is_main <<<"$found"

    [[ -d "$path" ]] || die "'$name' has no directory at $path"

    # stdout is the path alone — the fish wrapper cd's the shell into it.
    printf '%s\n' "$path"

    : "${reg:-}" "${branch:-}" "${state:-}" "${ahead:-}" "${behind:-}" "${locked:-}" "${age_s:-}" "${safe_clean:-}" "${is_main:-}"
}

# Removing a worktree leaves its branch behind, and `wt create <name>` refuses a
# taken branch — so a removed worktree takes its branch with it, never the default.
drop_branch() {
    local branch="$1"
    [[ -n "$branch" && "$branch" != "$DEFAULT_BRANCH" ]] || return 0
    git -C "$MAIN_WT" branch -D "$branch" >/dev/null 2>&1 || true
}

cmd_clean() {
    local dry_run=0 force=0 target=""
    while (( $# > 0 )); do
        case "$1" in
            --dry-run) dry_run=1; shift ;;
            --force)   force=1; shift ;;
            -*)        die "unknown flag: $1" ;;
            *)         target="$1"; shift ;;
        esac
    done
    (( force == 0 )) || [[ -n "$target" ]] \
        || die "--force needs a worktree name; a sweep never drops unmerged work"

    local rows
    rows=$(gather_worktrees "$MAIN_WT" "$DEFAULT_BRANCH")
    if [[ -z "$rows" ]]; then
        info "no worktrees"
        return 0
    fi

    local removed=0 skipped=0 matched=0 pid
    local name path reg branch state ahead behind locked age_s safe_clean is_main
    while IFS=$'\x1f' read -r name path reg branch state ahead behind locked age_s safe_clean is_main; do
        if [[ -n "$target" && "$name" != "$target" ]]; then
            continue
        fi
        matched=1

        # The main checkout is never a removal candidate.
        if (( is_main == 1 )); then
            [[ -n "$target" ]] && die "'$name' is the main checkout — cannot remove"
            continue
        fi

        # A no-target sweep reaps every safe worktree, but never one parked on the
        # default branch — a deliberate second checkout, not Claude's leftover.
        # Name it explicitly to remove it.
        if [[ -z "$target" && "$branch" == "$DEFAULT_BRANCH" ]]; then
            (( skipped += 1 ))
            continue
        fi

        if (( safe_clean == 0 )); then
            if [[ -n "$target" ]]; then
                if (( reg == 1 )); then
                    if (( locked == 1 )); then
                        die "'$name' is locked. Run: git -C '$MAIN_WT' worktree unlock '$path'"
                    elif (( force == 1 )); then
                        : # asked for by name: the uncommitted/unmerged work is the point
                    elif [[ "$state" != "clean" ]]; then
                        die "'$name' has uncommitted changes ($state); commit/stash inside the worktree first"
                    elif pid=$(in_use "$path"); then
                        die "'$name' is in use: process $pid has its cwd inside; close it, or name it with --force"
                    else
                        die "'$name' has $ahead commit(s) ahead of origin/$DEFAULT_BRANCH; run 'wt apply $name' to keep the work"
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
            elif (( force == 1 )); then
                git -C "$MAIN_WT" worktree remove --force "$path"
                drop_branch "$branch"
                info "removed (registered, force) $name"
            else
                git -C "$MAIN_WT" worktree remove "$path"
                drop_branch "$branch"
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
    : "${behind:-}" "${age_s:-}"
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

    # Landing mutates the main checkout, so gate before anything else (incl. the
    # picker and dry-run) — a dry-run that can't actually land should say why.
    require_main_on_clean_default

    local rows
    rows=$(gather_worktrees "$MAIN_WT" "$DEFAULT_BRANCH")
    [[ -n "$rows" ]] || die "no worktrees"

    if [[ -z "$target" ]]; then
        local choices
        choices=$(printf '%s\n' "$rows" \
            | while IFS=$'\x1f' read -r n p r b s a beh lk age sc im; do
                if (( r == 1 && im == 0 )) && [[ -n "$b" && "${b#refs/heads/}" != "$DEFAULT_BRANCH" ]]; then
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

    local name path reg branch state ahead behind locked age_s safe_clean is_main
    IFS=$'\x1f' read -r name path reg branch state ahead behind locked age_s safe_clean is_main <<<"$found"

    (( is_main == 0 ))                   || die "'$name' is the main checkout — nothing to apply"
    (( reg == 1 ))                       || die "'$name' is an orphan — nothing to apply, run 'clean' instead"
    [[ -n "$branch" ]]                   || die "'$name' is detached (no branch to keep)"
    [[ "$branch" != "$DEFAULT_BRANCH" ]] || die "'$name' is on the default branch — nothing to apply"
    [[ "$state" == "clean" ]]            || die "'$name' has uncommitted changes ($state); commit or stash inside the worktree first"
    [[ "$ahead" != "-" && "$ahead" != "0" ]] \
        || die "'$name' has no commits ahead of origin/$DEFAULT_BRANCH; run 'clean'"
    (( locked == 0 ))                    || die "'$name' is locked. Run: git -C '$MAIN_WT' worktree unlock '$path'"

    if (( dry_run == 1 )); then
        info "would rebase $branch onto $DEFAULT_BRANCH, remove worktree, fast-forward $DEFAULT_BRANCH, and delete $branch"
        return 0
    fi

    # Rebase onto the LOCAL default branch — the exact ref we fast-forward below.
    # Rebasing onto origin/<default> instead would let the rebase base and the ff
    # target diverge (local <default> ahead of origin, i.e. unpushed commits),
    # stranding the land after the worktree is gone. A local land never depends on
    # the remote being current.
    local target_ref="$DEFAULT_BRANCH"
    git -C "$path" rev-parse --verify --quiet "refs/heads/$DEFAULT_BRANCH" >/dev/null 2>&1 \
        || die "no rebase target: local $DEFAULT_BRANCH does not exist"

    info "rebasing $branch onto $target_ref"
    if ! git -C "$path" rebase "$target_ref"; then
        git -C "$path" rebase --abort 2>/dev/null || true
        die "rebase conflict; resolve in $path"
    fi

    # How far $DEFAULT_BRANCH will advance, captured before we drop the worktree.
    local landed
    landed=$(git -C "$MAIN_WT" rev-list --count "$DEFAULT_BRANCH..$branch" 2>/dev/null || echo "?")

    info "removing worktree $path"
    git -C "$MAIN_WT" worktree remove "$path"

    # Land: fast-forward the default branch onto the rebased work, then drop the
    # now-merged branch. Because we rebased onto local $DEFAULT_BRANCH, the branch
    # is a strict descendant of it, so --ff-only cannot conflict. If a step still
    # fails, the rebased branch stays staged in the main checkout (the pre-landing
    # behavior) — strictly no worse than before.
    if ! git -C "$MAIN_WT" merge --ff-only "$branch"; then
        die "could not fast-forward $DEFAULT_BRANCH onto $branch; the rebased branch is staged in $MAIN_WT — merge it manually"
    fi
    # Force-delete is safe: the ff above proves $branch is contained in
    # $DEFAULT_BRANCH. Plain 'branch -d' would refuse here whenever the branch
    # tracks origin/<default>, which still lacks the (unpushed) landed commits.
    if git -C "$MAIN_WT" merge-base --is-ancestor "$branch" HEAD 2>/dev/null; then
        git -C "$MAIN_WT" branch -D "$branch" >/dev/null
    else
        info "landed $branch but it is not contained in $DEFAULT_BRANCH; left in place — inspect with: git -C '$MAIN_WT' log $DEFAULT_BRANCH..$branch"
    fi

    info "landed $branch ($landed commit(s)) onto $DEFAULT_BRANCH"

    : "${behind:-}" "${age_s:-}" "${safe_clean:-}"
}

cmd_diff() {
    local target=""
    while (( $# > 0 )); do
        case "$1" in
            -*) die "unknown flag: $1" ;;
            *)  target="$1"; shift ;;
        esac
    done

    command -v diffnav >/dev/null 2>&1 \
        || die "diffnav not found on PATH"

    local rows
    rows=$(gather_worktrees "$MAIN_WT" "$DEFAULT_BRANCH")
    [[ -n "$rows" ]] || die "no worktrees"

    if [[ -z "$target" ]]; then
        local choices
        choices=$(printf '%s\n' "$rows" \
            | while IFS=$'\x1f' read -r n p r b s a beh lk age sc im; do
                if (( r == 1 && im == 0 )); then
                    local b_disp="${b#refs/heads/}"
                    [[ -n "$b_disp" ]] || b_disp="(detached)"
                    printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$n" "$b_disp" "$s" \
                        "$(format_vs "$a" "$beh")" "$(format_age "$age")"
                fi
                : "$p" "$lk" "$sc"
            done)
        if [[ -z "$choices" ]]; then
            die "no registered worktrees to diff"
        fi
        local picked
        picked=$({ printf 'NAME\tBRANCH\tSTATE\tvs main\tAGE\n'; printf '%s\n' "$choices"; } \
            | column -t -s $'\t' \
            | fzf --prompt="diff > " --header-lines=1 --layout=reverse --height=40%) \
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

    local name path reg branch state ahead behind locked age_s safe_clean is_main
    IFS=$'\x1f' read -r name path reg branch state ahead behind locked age_s safe_clean is_main <<<"$found"

    (( is_main == 0 )) || die "'$name' is the main checkout — nothing to diff"
    (( reg == 1 ))     || die "'$name' is an orphan — nothing to diff"
    [[ -n "$branch" ]] || die "'$name' is detached — no branch to diff"

    # Diff against the same base 'apply' rebases onto (local <default>), so
    # review == what lands. Fall back to origin/<default> only when the local ref
    # is missing (e.g. a fresh clone without a local default branch).
    local base_ref=""
    if git -C "$path" rev-parse --verify --quiet "refs/heads/$DEFAULT_BRANCH" >/dev/null 2>&1; then
        base_ref="$DEFAULT_BRANCH"
    elif git -C "$path" rev-parse --verify --quiet "refs/remotes/origin/$DEFAULT_BRANCH" >/dev/null 2>&1; then
        base_ref="origin/$DEFAULT_BRANCH"
    else
        die "no base to diff against: neither local $DEFAULT_BRANCH nor origin/$DEFAULT_BRANCH exists"
    fi

    if [[ "$ahead" == "0" && "$state" == "clean" ]]; then
        info "'$name' has no changes vs $DEFAULT_BRANCH"
        return 0
    fi

    # git diff can't show untracked files; flag them so they aren't a blind spot.
    if [[ -n "$(git -C "$path" ls-files --others --exclude-standard 2>/dev/null)" ]]; then
        info "note: '$name' has untracked files not shown in this diff"
    fi

    # Diff from the merge base to the WORKING TREE, so committed work and
    # uncommitted (tracked) changes both show. Run through diffnav's --watch so the
    # view auto-refreshes as the worktree changes; in watch mode diffnav runs the
    # command itself, so cd into the worktree and keep the command path-free.
    # Unrelated histories (orphan branch, recreated default) have no merge base and
    # would make git fatal, so fall back to a plain diff of the base ref.
    local mb
    if mb=$(git -C "$path" merge-base "$base_ref" HEAD 2>/dev/null); then
        ( cd "$path" && diffnav --watch --watch-cmd "git diff $mb" )
    else
        info "'$name' shares no history with $DEFAULT_BRANCH; showing full diff"
        ( cd "$path" && diffnav --watch --watch-cmd "git diff $base_ref" )
    fi

    : "${behind:-}" "${locked:-}" "${age_s:-}" "${safe_clean:-}"
}

cmd_smerge() {
    local target=""
    while (( $# > 0 )); do
        case "$1" in
            -*) die "unknown flag: $1" ;;
            *)  target="$1"; shift ;;
        esac
    done

    command -v smerge >/dev/null 2>&1 \
        || die "sublime-merge ('smerge') not found on PATH"

    local rows
    rows=$(gather_worktrees "$MAIN_WT" "$DEFAULT_BRANCH")
    [[ -n "$rows" ]] || die "no worktrees"

    if [[ -z "$target" ]]; then
        local choices
        choices=$(printf '%s\n' "$rows" \
            | while IFS=$'\x1f' read -r n p r b s a beh lk age sc im; do
                if (( r == 1 && im == 0 )); then
                    local b_disp="${b#refs/heads/}"
                    [[ -n "$b_disp" ]] || b_disp="(detached)"
                    printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$n" "$b_disp" "$s" \
                        "$(format_vs "$a" "$beh")" "$(format_age "$age")"
                fi
                : "$p" "$lk" "$sc"
            done)
        if [[ -z "$choices" ]]; then
            die "no registered worktrees to open"
        fi
        local picked
        picked=$({ printf 'NAME\tBRANCH\tSTATE\tvs main\tAGE\n'; printf '%s\n' "$choices"; } \
            | column -t -s $'\t' \
            | fzf --prompt="smerge > " --header-lines=1 --layout=reverse --height=40%) \
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

    local name path reg branch state ahead behind locked age_s safe_clean is_main
    IFS=$'\x1f' read -r name path reg branch state ahead behind locked age_s safe_clean is_main <<<"$found"

    (( is_main == 0 )) || die "'$name' is the main checkout — open it directly"
    (( reg == 1 ))     || die "'$name' is an orphan — nothing to open"

    info "opening $path in sublime-merge"
    smerge "$path" </dev/null >/dev/null 2>&1 &
    disown

    : "${branch:-}" "${state:-}" "${ahead:-}" "${behind:-}" "${locked:-}" "${age_s:-}" "${safe_clean:-}"
}

cmd_code() {
    local target=""
    while (( $# > 0 )); do
        case "$1" in
            -*) die "unknown flag: $1" ;;
            *)  target="$1"; shift ;;
        esac
    done

    command -v code >/dev/null 2>&1 \
        || die "VS Code ('code') not found on PATH"

    local rows
    rows=$(gather_worktrees "$MAIN_WT" "$DEFAULT_BRANCH")
    [[ -n "$rows" ]] || die "no worktrees"

    if [[ -z "$target" ]]; then
        local choices
        choices=$(printf '%s\n' "$rows" \
            | while IFS=$'\x1f' read -r n p r b s a beh lk age sc im; do
                if (( r == 1 && im == 0 )); then
                    local b_disp="${b#refs/heads/}"
                    [[ -n "$b_disp" ]] || b_disp="(detached)"
                    printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$n" "$b_disp" "$s" \
                        "$(format_vs "$a" "$beh")" "$(format_age "$age")"
                fi
                : "$p" "$lk" "$sc"
            done)
        if [[ -z "$choices" ]]; then
            die "no registered worktrees to open"
        fi
        local picked
        picked=$({ printf 'NAME\tBRANCH\tSTATE\tvs main\tAGE\n'; printf '%s\n' "$choices"; } \
            | column -t -s $'\t' \
            | fzf --prompt="code > " --header-lines=1 --layout=reverse --height=40%) \
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

    local name path reg branch state ahead behind locked age_s safe_clean is_main
    IFS=$'\x1f' read -r name path reg branch state ahead behind locked age_s safe_clean is_main <<<"$found"

    (( is_main == 0 )) || die "'$name' is the main checkout — open it directly"
    (( reg == 1 ))     || die "'$name' is an orphan — nothing to open"

    info "opening $path in VS Code"
    code -n "$path" >/dev/null 2>&1 \
        || die "failed to open VS Code for $path"

    : "${branch:-}" "${state:-}" "${ahead:-}" "${behind:-}" "${locked:-}" "${age_s:-}" "${safe_clean:-}"
}

cmd_names() {
    local rows
    rows=$(gather_worktrees "$MAIN_WT" "$DEFAULT_BRANCH")
    [[ -n "$rows" ]] || return 0
    printf '%s\n' "$rows" | cut -d $'\x1f' -f1
}

# Move this repo's worktrees that predate the root into it. git does the moving,
# so branches and registrations come along; anything dirty, locked, or orphaned
# is reported and left where it is.
cmd_migrate() {
    local dry_run=0
    while (( $# > 0 )); do
        case "$1" in
            --dry-run) dry_run=1; shift ;;
            *)         die "unknown flag: $1" ;;
        esac
    done

    local wt_dir
    wt_dir=$(worktree_dir "$MAIN_WT")

    local rows
    rows=$(gather_worktrees "$MAIN_WT" "$DEFAULT_BRANCH")

    (( dry_run == 1 )) || mkdir -p "$wt_dir"

    local moved=0 skipped=0
    local name path reg branch state ahead behind locked age_s safe_clean is_main dest
    while IFS=$'\x1f' read -r name path reg branch state ahead behind locked age_s safe_clean is_main; do
        [[ -n "$path" ]] || continue
        if (( is_main == 1 )); then continue; fi
        if [[ "$path" == "$wt_dir"/* ]]; then continue; fi

        if (( reg == 0 )); then
            info "left orphan $path in place — inspect it, then 'wt clean' or move it yourself"
            skipped=$(( skipped + 1 ))
            continue
        fi

        dest="$wt_dir/$name"
        if [[ -e "$dest" ]]; then
            info "skipped $name: $dest already exists"
            skipped=$(( skipped + 1 ))
            continue
        fi

        if (( dry_run == 1 )); then
            info "would move $path -> $dest"
            moved=$(( moved + 1 ))
            continue
        fi

        if git -C "$MAIN_WT" worktree move "$path" "$dest" 2>/dev/null; then
            info "moved $name -> $dest"
            moved=$(( moved + 1 ))
        else
            info "skipped $name: git would not move it (locked, or holds submodules); unlock with: git -C '$MAIN_WT' worktree unlock '$path'"
            skipped=$(( skipped + 1 ))
        fi
    done <<<"$rows"

    if (( dry_run == 1 )); then
        info "would move $moved, $skipped left"
    elif (( moved > 0 )); then
        git -C "$MAIN_WT" worktree prune
        info "moved $moved into $wt_dir, $skipped left alone"
    else
        info "nothing to move, $skipped left alone"
    fi

    : "${branch:-}" "${state:-}" "${ahead:-}" "${behind:-}" "${locked:-}" "${age_s:-}" "${safe_clean:-}"
}

# --- guard ------------------------------------------------------------------

# Split a shell command into words, dropping quotes and turning each command
# separator into a __SEP__ token. Expansions are not evaluated: a $var path stays
# literal, so the guard refuses it rather than guess.
shell_tokens() {
    local s="$1" n=${#1} i=0 word="" have=0 c q
    while (( i < n )); do
        c=${s:i:1}
        case "$c" in
            ' '|$'\t'|$'\r')
                if (( have )); then printf '%s\x1f' "$word"; word=""; have=0; fi
                ;;
            $'\n'|';'|'|'|'&'|'('|')')
                if (( have )); then printf '%s\x1f' "$word"; word=""; have=0; fi
                printf '\x1f__SEP__\x1f'
                ;;
            "'"|'"')
                q="$c"
                i=$(( i + 1 ))
                while (( i < n )) && [[ "${s:i:1}" != "$q" ]]; do
                    # A backslash only escapes inside double quotes.
                    if [[ "$q" == '"' && "${s:i:1}" == "\\" ]] && (( i + 1 < n )); then i=$(( i + 1 )); fi
                    word+="${s:i:1}"
                    i=$(( i + 1 ))
                done
                have=1
                ;;
            \\)
                i=$(( i + 1 ))
                word+="${s:i:1}"
                have=1
                ;;
            *)
                word+="$c"
                have=1
                ;;
        esac
        i=$(( i + 1 ))
    done
    if (( have )); then printf '%s\x1f' "$word"; fi
}

# Parse a `git [global opts] worktree add [opts] <path>` call that starts at
# arr[start]. Sets ADD_FOUND, ADD_PATH, ADD_BRANCH (-b/-B value) and ADD_END.
parse_git_add() {
    local -n arr="$1"
    local i=$2 n=${#arr[@]} t
    ADD_FOUND=0 ADD_PATH="" ADD_BRANCH="" ADD_END=$(( i + 1 ))

    i=$(( i + 1 ))
    while (( i < n )); do
        t="${arr[i]}"
        case "$t" in
            __SEP__) return 0 ;;
            -C|-c) i=$(( i + 2 )); continue ;;
            --git-dir=*|--work-tree=*|--exec-path=*|--namespace=*|--config-env=*|--super-prefix=*)
                i=$(( i + 1 )); continue ;;
            -p|-P|--paginate|--no-pager|--bare|--no-replace-objects|--literal-pathspecs|--glob-pathspecs|--noglob-pathspecs|--icase-pathspecs|--no-optional-locks|--no-advice)
                i=$(( i + 1 )); continue ;;
            -*) i=$(( i + 1 )); continue ;;
        esac
        break
    done

    [[ "${arr[i]:-}" == worktree && "${arr[i+1]:-}" == add ]] || return 0

    i=$(( i + 2 ))
    while (( i < n )); do
        t="${arr[i]}"
        case "$t" in
            __SEP__) break ;;
            --)
                i=$(( i + 1 ))
                if (( i < n )) && [[ "${arr[i]}" != __SEP__ ]]; then
                    ADD_PATH="${arr[i]}"
                    i=$(( i + 1 ))
                fi
                break
                ;;
            -b|-B) ADD_BRANCH="${arr[i+1]:-}"; i=$(( i + 2 )); continue ;;
            --reason) i=$(( i + 2 )); continue ;;
            -*) i=$(( i + 1 )); continue ;;
        esac
        ADD_PATH="$t"
        i=$(( i + 1 ))
        break
    done

    ADD_FOUND=1
    ADD_END=$i
}

guard_reason() {
    local dir="$1" path="$2" branch="${3:-}" name="<name>"
    if [[ -n "$path" && "$path" != *'$'* ]]; then
        name=$(basename "$path")
    fi
    [[ -n "$branch" ]] || branch="<branch>"
    cat <<EOF
Blocked: git worktree add outside the shared worktree root.
Worktrees live in $WORKTREE_ROOT/<repo>/, never inside a checkout, so they don't pile up.
Use one of:
  wt create $name <base>                 # new branch off <base> (default: the default branch)
  git worktree add $dir/$name $branch    # keeps the branch you asked for
EOF
}

# Exit 1 with a reason when <command> would create a worktree outside the root,
# exit 0 when it stays inside (or there is no repo to steer).
cmd_guard() {
    (( $# == 1 )) || return 0

    local cmd="$1" dir
    dir=$(worktree_dir .) || return 0

    local -a toks=()
    local tok
    while IFS= read -r -d $'\x1f' tok; do toks+=("$tok"); done < <(shell_tokens "$cmd")

    local i=0 n=${#toks[@]} at_start=1 block=0 offender=""
    while (( i < n )); do
        tok="${toks[i]}"
        if [[ "$tok" == __SEP__ ]]; then
            at_start=1
            i=$(( i + 1 ))
            continue
        fi
        if (( at_start )); then
            case "$tok" in
                *=*) i=$(( i + 1 )); continue ;;
                command|builtin|exec|nohup|time|nice|sudo|env) i=$(( i + 1 )); continue ;;
                git|*/git)
                    parse_git_add toks "$i"
                    if (( ADD_FOUND )); then
                        if ! in_worktree_root "$dir" "$ADD_PATH"; then
                            block=1
                            offender="$ADD_PATH"
                        fi
                        i=$ADD_END
                        at_start=0
                        continue
                    fi
                    ;;
            esac
            at_start=0
        fi
        i=$(( i + 1 ))
    done

    (( block )) || return 0
    guard_reason "$dir" "$offender" "$ADD_BRANCH"
    return 1
}

# --- main -------------------------------------------------------------------

if (( $# == 0 )); then
    usage
    exit 1
fi

verb="$1"; shift

# Guard runs inside agent hooks, which may sit outside any repo, and exit 1 means
# "blocked" — so it must not go through the repo-required prelude below.
if [[ "$verb" == guard ]]; then
    cmd_guard "$@"
    exit $?
fi

MAIN_WT=$(find_main_worktree)
DEFAULT_BRANCH=$(find_default_branch "$MAIN_WT")
build_registration_maps "$MAIN_WT"

case "$verb" in
    list)            cmd_list "$@" ;;
    create)          cmd_create "$@" ;;
    cd)              cmd_cd "$@" ;;
    clean)           cmd_clean "$@" ;;
    apply)           cmd_apply "$@" ;;
    diff)            cmd_diff "$@" ;;
    smerge)          cmd_smerge "$@" ;;
    code)            cmd_code "$@" ;;
    migrate)         cmd_migrate "$@" ;;
    names)           cmd_names "$@" ;;
    status)          cmd_status "$@" ;;
    -h|--help|help)  usage ;;
    *)               usage; exit 1 ;;
esac
