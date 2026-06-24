#!/usr/bin/env bash
set -euo pipefail

# wt: manage git worktrees. Discovery is git-driven (every worktree registered
# to the repo, wherever it lives), with the dirs under <repo>/.claude/worktrees/
# scanned on top to surface orphans (Claude's home, the only dir we know to scan).
#
# Verbs:
#   list                       Show every worktree with state (incl. a (main) row).
#   create <name> [<base>]     Create <repo>/.claude/worktrees/<name> on a new
#                              branch <name> off <base> (default: <default>).
#                              Prints the new worktree's path on stdout.
#   clean [--dry-run] [<name>] Remove safely-removable worktrees. No name: clean
#                              every safe one (never main, never one parked on
#                              <default>). With name: clean that one.
#   apply [--dry-run] [<name>] Land the worktree's branch: rebase onto
#                              <default>, remove the worktree, fast-forward
#                              <default>, and delete the branch.
#                              Requires the main checkout on a clean <default>.
#   diff [<name>]              Review the worktree's diff (committed +
#                              uncommitted) vs <default> in diffnav --watch.
#   smerge [<name>]            Open the worktree in Sublime Merge.
#   code [<name>]              Open the worktree in VS Code.

usage() {
    cat >&2 <<'EOF'
Usage:
  wt list
  wt create <name> [<base>]
  wt clean [--dry-run] [<name>]
  wt apply [--dry-run] [<name>]
  wt diff [<name>]
  wt smerge [<name>]
  wt code [<name>]
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
# orphan dirs under <main>/.claude/worktrees/ that git no longer tracks.
# Fields: name path registered branch state ahead behind locked age_seconds safe_clean is_main
# 'name' is the path basename; basenames shared across worktrees are
# disambiguated to <parent>/<base> on the colliding rows only.
gather_worktrees() {
    local main="$1" default_branch="$2"
    local wt_dir="$main/.claude/worktrees"

    # Path set: every registered worktree (main first so it heads the listing),
    # then orphan dirs under .claude/worktrees/ git doesn't know about.
    local -A seen=()
    local -a paths=()
    local p
    paths+=("$main"); seen["$main"]=1
    for p in "${!REG_BRANCH[@]}"; do
        [[ -n "${seen[$p]+s}" ]] && continue
        paths+=("$p"); seen["$p"]=1
    done
    if [[ -d "$wt_dir" ]]; then
        for p in "$wt_dir"/*/; do
            [[ -d "$p" ]] || continue
            p="${p%/}"
            [[ -n "${seen[$p]+s}" ]] && continue
            paths+=("$p"); seen["$p"]=1
        done
    fi

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
    local porcelain ab mt parent
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

            if git -C "$p" rev-parse --verify --quiet "refs/remotes/origin/${default_branch}" >/dev/null 2>&1; then
                if ab=$(git -C "$p" rev-list --left-right --count "refs/remotes/origin/${default_branch}...HEAD" 2>/dev/null); then
                    behind=$(awk '{print $1}' <<<"$ab")
                    ahead=$(awk  '{print $2}' <<<"$ab")
                fi
            elif git -C "$p" rev-parse --verify --quiet "refs/heads/${default_branch}" >/dev/null 2>&1; then
                if ab=$(git -C "$p" rev-list --left-right --count "refs/heads/${default_branch}...HEAD" 2>/dev/null); then
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
    # them so the worktree path stays one level under .claude/worktrees/.
    local branch="$name"
    local dir_name="${name//\//-}"
    local wt_dir="$MAIN_WT/.claude/worktrees"
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
    elif git -C "$MAIN_WT" rev-parse --verify --quiet "refs/remotes/origin/$DEFAULT_BRANCH" >/dev/null 2>&1; then
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

    # stdout is the path alone — for `cd (wt create ...)` and scripting.
    printf '%s\n' "$path"
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
        info "no worktrees"
        return 0
    fi

    local removed=0 skipped=0 matched=0
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
                    elif [[ "$state" != "clean" ]]; then
                        die "'$name' has uncommitted changes ($state); commit/stash inside the worktree first"
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
    create)          cmd_create "$@" ;;
    clean)           cmd_clean "$@" ;;
    apply)           cmd_apply "$@" ;;
    diff)            cmd_diff "$@" ;;
    smerge)          cmd_smerge "$@" ;;
    code)            cmd_code "$@" ;;
    -h|--help|help)  usage ;;
    *)               usage; exit 1 ;;
esac
