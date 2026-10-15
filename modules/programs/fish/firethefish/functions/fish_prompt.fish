# Segment drawing, layout and colors ported from bobthefish (MIT, Copyright (c) 2013-2021 Justin Hileman).

function fish_prompt
    set -l last_pipestatus $pipestatus
    set -l last_status $status
    if test "$TERM" = dumb
        echo -n '> '
        return
    end
    # The final rendering and a k8s pill repaint follow a full render of the same prompt, so replay it instead of forking git again.
    if contains -- --final-rendering $argv; or set -q __ftf_replay_left
        set -e __ftf_replay_left
        printf %s $__ftf_left
        return
    end
    set -g __ftf_cols $COLUMNS
    # Shared with fish_right_prompt, which always renders right after this in the same paint.
    set -g __ftf_job_states
    jobs -q; and set __ftf_job_states (__ftf_jobs)
    set -l real_pwd (builtin pwd -P 2>/dev/null | string collect); or set real_pwd $PWD
    set -g __ftf_bg
    set -l head (
        begin
            __ftf_prompt_status $last_status $last_pipestatus
            __ftf_prompt_user
            __ftf_prompt_direnv $real_pwd
            __ftf_prompt_nix
            __ftf_prompt_venv
        end | string collect
    )
    set -l head_bg $__ftf_bg
    set -l repo (__ftf_repo_scan $real_pwd)
    set -q repo[1]; and set repo $repo[1] (__ftf_git_parse $repo[2..])
    # Leave room to type: shorten step by step until a third of the width (at least 20 columns) stays free.
    set -l room (math "max(20, floor($COLUMNS / 3))")
    # Only the levels that change this prompt's rendering: a branch over 20 cells, a subdirectory below the root.
    set -l levels 0
    if set -q repo[1]
        test (string length --visible -- "$repo[4]") -gt 20; and set -a levels 1
        test "$real_pwd" != "$repo[1]"; and set -a levels 2 3
    end
    for level in $levels 4
        set -g __ftf_bg $head_bg
        set -g __ftf_left "$head"(
            begin
                __ftf_prompt_dir $level $real_pwd $repo
                __ftf_finish_segments
            end | string collect
        )
        test (math $COLUMNS - (string length --visible -- $__ftf_left)) -ge $room; and break
    end
    printf %s $__ftf_left
end

function __ftf_start_segment -a bg fg
    set_color normal
    set_color -b $bg $fg $argv[3..]
    switch "$__ftf_bg"
        case ''
            echo -n ' '
        case $bg
            echo -n \uE0B1' '
        case '*'
            set_color $__ftf_bg
            echo -n \uE0B0' '
            set_color $fg $argv[3..]
    end
    set -g __ftf_bg $bg
end

function __ftf_finish_segments
    if test -n "$__ftf_bg"
        set_color normal
        set_color $__ftf_bg
        echo -n \uE0B0' '
    end
    set_color normal
    set -g __ftf_bg
end

function __ftf_prompt_status -a last_status
    set -l pipe $argv[2..]
    set -l parts
    if test "$__ftf_fresh" = 1; and test "$last_status" -ne 0
        set -l mixed (string match -v -- $pipe[1] $pipe)
        set -q mixed[1]; or set pipe $last_status
        if test "$pipe" = 130
            set -a parts yellow '^C'
        else
            set -a parts red '! '(fish_status_to_signal $pipe | string join '|')
        end
    end
    set -q fish_private_mode[1]; and set -a parts black \uF023
    not set -q SHELL_PROMPT_PREFIX; and fish_is_root_user; and set -a parts green '$'
    contains running (string split -f1 ' ' -- $__ftf_job_states); and set -a parts blue '%'
    test "$__ftf_depth" -gt 0 2>/dev/null; and set -a parts black ⤵$__ftf_depth
    set -q parts[1]; or return

    __ftf_start_segment white black
    while set -q parts[2]
        set_color normal
        if test $parts[1] = black
            set_color -b white black
        else
            set_color -b white $parts[1] --bold
        end
        echo -n "$parts[2] "
        set -e parts[1..2]
    end
end

function __ftf_prompt_user
    set -q SSH_CLIENT; or set -q SSH_TTY; or return
    __ftf_start_segment white black --bold
    echo -n $USER
    set_color normal
    set_color -b white black
    echo -n "@"(prompt_hostname)" "
end

function __ftf_prompt_direnv -a real_pwd
    functions -q __direnv_export_eval; or return
    set -l rcs /.envrc
    set -l dir
    for part in (string split -n / -- $real_pwd)
        set dir "$dir/$part"
        set -p rcs $dir/.envrc
    end
    set -l rc (path filter -f -- $rcs)[1]
    set -q rc[1]; or return
    set dir (path dirname -- $rc)
    # direnv records the physical path.
    if set -q DIRENV_DIR[1]; and test "$(path resolve -- (string sub -s 2 -- $DIRENV_DIR))" = $dir
        # direnv keeps DIRENV_DIR on a blocked .envrc too; only the compressed DIRENV_WATCHES tells, so ask once per change.
        if test "$DIRENV_WATCHES" != "$__ftf_direnv_key"
            set -g __ftf_direnv_key $DIRENV_WATCHES
            set -g __ftf_direnv_allowed
            # Ask the binary the hook calls; direnv itself need not be on PATH (e.g. a pure nix shell).
            set -l bin (functions __direnv_export_eval | string match -rg '^\s*"?([^"\s]+)"? export fish')[1]
            if command -q -- "$bin"
                set -l json (command $bin status --json 2>/dev/null | string collect)
                set __ftf_direnv_allowed (string match -rg '"foundRC": \{\s*"allowed": (\d)' -- "$json")
            end
        end
        # 0 is allowed, 2 is an explicit `direnv deny`.
        test "$__ftf_direnv_allowed" = 1; or return
    end
    __ftf_start_segment brred black --bold
    if path filter -rq -- $rc; and string match -qr '^\s*use\s+(flake|nix)\b' <$rc
        echo -n \uF313' blocked '
    else
        echo -n '.envrc blocked '
    end
end

function __ftf_prompt_nix
    set -q IN_NIX_SHELL[1]; or return
    __ftf_start_segment brblue black --bold
    set -l label
    if not set -q DIRENV_DIR
        set label $name
        test "$label" = nix-shell; and set label $__ftf_nix_dir
    end
    echo -n (string join ' ' \uF313 $label)' '
end

function __ftf_prompt_venv
    set -l env $VIRTUAL_ENV $CONDA_DEFAULT_ENV
    set -q env[1]; or return
    __ftf_start_segment brblue black --bold
    echo -n \uE73C (path basename -- $env[1])' '
end

function __ftf_path_segment -a dir level
    set -l bg black
    set -l fg white
    if not test -w $dir
        set bg magenta
        set fg black
    end
    __ftf_start_segment $bg $fg
    set -l home (path resolve -- ~)
    switch $dir
        case /
            set dir /
        case $home
            set dir '~'
        case '*'
            if test $level -lt 4
                set -l parent (string replace -r -- '^'(string escape --style=regex $home)'($|/)' '~$1' (path dirname -- $dir))
                echo -n (string replace -ar -- '(\.?[^/])[^/]*/' '$1/' (string trim -r -c / -- $parent)/)
            end
            set dir (path basename -- $dir)
    end
    set_color -b $bg $fg --bold
    echo -n "$dir "
end

function __ftf_repo_scan -a real_pwd -d 'Print repo root, git dir, common dir, short HEAD and porcelain status lines when real_pwd is inside a work tree'
    set -l rp
    # Outside a work tree (no repo, inside .git, bare repo) rev-parse fails and the path is shown alone.
    # Its output is newline-separated, so a path containing a newline can't be read back.
    not string match -q \*\n\* -- $real_pwd; and __ftf_in_repo $real_pwd; and command -q git
    and set rp (command git rev-parse --path-format=absolute --show-toplevel --absolute-git-dir --git-common-dir --short HEAD 2>/dev/null)
    set -q rp[3]; and string match -q -- "$rp[1]/*" "$real_pwd/"; or return
    set -l lines (command git --no-optional-locks status --porcelain=v2 --branch 2>/dev/null); or return
    printf '%s\n' $rp[1..3] "$rp[4]" $lines
end

function __ftf_git_parse -a gitdir commondir short_head -d 'Print the git segment as six lines: colors, glyphs, branch, state, arrows, stale mark'
    set -l lines $argv[4..]
    set -l head (string replace -rf '^# branch\.head ' '' -- $lines)
    set -l ab (string match -rg '^# branch\.ab \+(\d+) -(\d+)$' -- $lines)
    set -l xy (string replace -rf '^[12] (..) .*' '$1' -- $lines)
    set -l staged (count (string match -r '^[^.]' -- $xy))
    set -l unstaged (count (string match -r '^.[^.]' -- $xy))
    set -l untracked (count (string match -r '^\? ' -- $lines))
    set -l conflicts (count (string match 'u *' -- $lines))
    set -l upstream (string replace -rf '^# branch\.upstream ' '' -- $lines)

    set -l op
    set -l step
    for f in $gitdir/rebase-merge/{msgnum,end} $gitdir/rebase-apply/{next,last}
        test -f $f; and set -a step (string trim <$f)
    end
    if test -d $gitdir/rebase-merge
        # msgnum and end appear only once the todo list has been saved.
        set op rebase
        set -q step[2]; and set op "$op $step[1]/$step[2]"
    else if test -d $gitdir/rebase-apply
        set op rebase
        test -f $gitdir/rebase-apply/applying; and set op am
        set -q step[2]; and set op "$op $step[1]/$step[2]"
    else if test -f $gitdir/MERGE_HEAD
        set op merge
    else if test -f $gitdir/CHERRY_PICK_HEAD
        set op cherry-pick
    else if test -f $gitdir/REVERT_HEAD
        set op revert
    else if test -f $gitdir/sequencer/todo
        # A multi-commit pick or revert keeps going after a hand-committed conflict, with no *_HEAD left.
        set -l next (string match -rv '^\s*(#|$)' <$gitdir/sequencer/todo)[1]
        switch "$next"
            case 'p *' 'pick *'
                set op cherry-pick
            case 'revert *'
                set op revert
        end
    end

    set -l color green black
    if set -q op[1]
        set color cyan black --bold
    else if test $unstaged -gt 0 -o $conflicts -gt 0
        set color brred black
    else if test $staged -gt 0
        set color yellow black
    end

    set -l glyphs
    test $gitdir != $commondir; and set -a glyphs 
    set -l branch
    if test "$head" = '(detached)'
        set -a glyphs 
        set branch $short_head
    else
        set -a glyphs 
        set -q __ftf_default_branches
        or set -g __ftf_default_branches main master (command git config --get init.defaultBranch)
        contains -- $head $__ftf_default_branches; or set branch $head
    end

    set -l state $op
    # Staged/unstaged show only through the segment colour; untracked-only stays green, so it gets a mark.
    test $untracked -gt 0; and set -a state '?'
    test $conflicts -gt 0; and set -a state "~$conflicts"
    set -l arrows
    set -l stale
    if set -q ab[1]
        test $ab[1] -gt 0; and set -a arrows ⇡$ab[1]
        test $ab[2] -gt 0; and set -a arrows ⇣$ab[2]
        set stale ◷
        # FETCH_HEAD is per worktree, but a fetch from any of them refreshes the shared remote refs.
        for age in (path mtime -R -- $commondir/FETCH_HEAD $commondir/worktrees/*/FETCH_HEAD)
            test $age -lt 86400; and set stale
        end
        # Clone and push leave no FETCH_HEAD; clone logs only the remote's HEAD, push only the ref it updates.
        set -l logs $commondir/logs/refs/remotes/$upstream $commondir/logs/refs/remotes/(string split -m1 -f1 / -- $upstream)/HEAD
        # gc's reflog expire rewrites every reflog, so only the last entry's own timestamp dates it.
        for log in (test -n "$stale"; and path filter -f -- $logs)
            set -l when (string match -rg '> (\d+) [+-]\d{4}(?:\t|$)' <$log)[-1]
            test -n "$when"; or continue
            # mtime plus age is now, without forking date.
            test (math (path mtime -- $log) + (path mtime -R -- $log) - $when) -lt 86400; and set stale
        end
    else if set -q upstream[1]; and not contains -- '# branch.oid (initial)' $lines
        # porcelain v2 omits branch.ab when the configured upstream ref no longer exists, and on unborn branches.
        set -a state 
    end
    printf '%s\n' "$color" "$glyphs" "$branch" "$state" "$(string join '' -- $arrows)" "$stale"
end

function __ftf_prompt_dir -a level real_pwd root color glyphs branch state arrows stale
    if test -z "$root"
        __ftf_path_segment $real_pwd $level
        return
    end

    __ftf_path_segment $root $level

    set color (string split ' ' -- $color)
    __ftf_start_segment $color
    test $level -ge 1 -a (string length --visible -- "$branch") -gt 20
    and set branch (string shorten -c '' -m 10 -- $branch)…(string shorten -c '' --left -m 9 -- $branch)
    echo -n (string join ' ' -- (string match -v '' -- $glyphs $branch $state))' '
    if test -n "$arrows$stale"
        test -n "$stale"; and set_color --dim
        echo -n $arrows
        if test -n "$stale"
            set_color normal
            set_color -b $color
            echo -n $stale
        end
        echo -n ' '
    end

    if test "$real_pwd" != "$root" -a $level -lt 3
        if test -w $real_pwd
            __ftf_start_segment black white
        else
            __ftf_start_segment magenta black
        end
        set -l sub (string replace -- "$root/" '' $real_pwd)
        test $level -ge 2; and set sub (string replace -ar -- '(\.?[^/])[^/]*/' '$1/' $sub)
        echo -n "$sub "
    end
end
