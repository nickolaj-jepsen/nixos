status is-interactive; or return

set -g fish_transient_prompt 1
set -gx VIRTUAL_ENV_DISABLE_PROMPT 1

# nix develop / nix-shell start a fresh fish in the project dir; remember it as the env's name.
set -q IN_NIX_SHELL[1]; and not set -q DIRENV_DIR; and set -g __ftf_nix_dir (path basename -- $PWD)

# Nesting depth within this pane/SSH session: a deeper SHLVL than the parent fish's is one level down (nix-shell's bash adds two, exec none).
set -l scope "$ZELLIJ_SESSION_NAME/$ZELLIJ_PANE_ID/$TMUX_PANE/$SSH_CONNECTION"
set -l nest (string split -m2 ' ' -- "$__ftf_nest")
set -g __ftf_depth 0
if string match -qr '^\d+ \d+ ' -- "$__ftf_nest"; and test "$nest[3]" = "$scope"
    set __ftf_depth $nest[1]
    test "$SHLVL" -gt $nest[2] 2>/dev/null; and set __ftf_depth (math $__ftf_depth + 1)
end
set -gx __ftf_nest $__ftf_depth $SHLVL $scope

# nix shell sets no marker, so name the store bin dirs it put on PATH beyond those of the fish that ran it.
set -g __ftf_nix_pkgs
if set -q __ftf_store_path; and not set -q IN_NIX_SHELL[1]
    # Exported lists arrive space-joined.
    set -l parent (string split ' ' -- "$__ftf_store_path")
    for p in (string match -- '/nix/store/*' $PATH)
        contains -- $p $parent; and continue
        set -l pkg (string match -rg '^/nix/store/[a-z0-9]{32}-(.+?)(?:-\d[^/]*)?/bin$' -- $p)
        set -q pkg[1]; and not contains -- $pkg $__ftf_nix_pkgs; and set -a __ftf_nix_pkgs $pkg
    end
end
set -gx __ftf_store_path (string match -- '/nix/store/*' $PATH)

# An empty Enter fires no fish_postexec, so this marks $status and $CMD_DURATION as belonging to this prompt.
set -g __ftf_ran 0
function __ftf_on_preexec --on-event fish_preexec
    set -e __ftf_job_stopped
    set -g __ftf_last_pid $last_pid
    set -gx __ftf_store_path (string match -- '/nix/store/*' $PATH)
end
function __ftf_on_postexec --on-event fish_postexec
    __ftf_job_unstash $argv[1]
    # Blank or comment-only lines, launching or suspending a job all leave the previous $status in place.
    string match -qr '^\s*(#.*)?$' -- $argv[1]; and return
    # The text alone can't tell `&` from `\&` or a commented `&`; a new $last_pid confirms a launch.
    test "$last_pid" != "$__ftf_last_pid"; and string match -qr '&\s*(#.*)?$' -- $argv[1]; and return
    set -g __ftf_ran 1
end
function __ftf_on_prompt --on-event fish_prompt
    set -g __ftf_fresh $__ftf_ran
    set -q __ftf_job_stopped; and set __ftf_fresh 0
    set -g __ftf_ran 0
    set -e __ftf_replay_left
    __ftf_stash_pop
end

# Repaint only when the magenta k8s pill would appear or disappear.
function __ftf_k8s_check
    # The pager swaps in its selection only after the binding runs; the next key outside it re-checks.
    commandline --paging-mode; and return
    set -l want 0
    test "$__ftf_k8s_dev" = 1; and __ftf_k8s_wanted; and set want 1
    test $want = "$__ftf_k8s_shown"; and return
    set -g __ftf_k8s_shown $want
    set -g __ftf_replay_left
    commandline -f repaint
end

# Append the k8s check to whatever edits, recalls or completes the line; presets are only complete by the first prompt.
function __ftf_bind_k8s --on-event fish_prompt
    set -q __ftf_k8s_bound; and test "$__ftf_k8s_bound" = "$fish_key_bindings"; and return
    set -g __ftf_k8s_bound $fish_key_bindings
    # Copies of the old set's presets are user bindings, so they would shadow the new set's presets.
    for mk in $__ftf_k8s_copies
        set mk (string split ' ' -- $mk)
        bind --user -M $mk 2>/dev/null | string match -q '*__ftf_k8s_check'
        and bind --user -e -M $mk
    end
    set -g __ftf_k8s_copies
    set -l keys space shift-space backspace shift-backspace delete shift-delete ctrl-h ctrl-d ctrl-w ctrl-u ctrl-k \
        alt-d alt-backspace ctrl-backspace ctrl-alt-h alt-delete ctrl-delete ctrl-c ctrl-z ctrl-/ ctrl-_ alt-/ \
        ctrl-shift-z alt-t ctrl-t alt-u alt-c alt-e alt-v alt-s escape ctrl-g ctrl-r up down ctrl-p ctrl-n alt-up alt-down pageup \
        pagedown alt-. right ctrl-f end ctrl-e alt-right alt-f tab shift-tab
    set -l head '^bind(?: --\w+| -[Mm] \S+)* '
    set -l re $head'(?:'(string escape --style=regex -- $keys | string join '|')')(?: |$)'
    set -l binds
    for mode in (bind -L)
        set -l user (bind --user -M $mode | string match -r -- $re.\*)
        set -l preset (bind --preset -M $mode | string match -r -- $re.\*)
        # A user binding shadows the preset for the same key.
        set -l taken (string replace -r -- $head'(\S+).*' '$1' $user | string escape --style=regex)
        set -q taken[1]; and set preset (string match -rv -- $head'(?:'(string join '|' -- $taken)')(?: |$)' $preset)
        set -a binds (string match -v -- '* __ftf_k8s_check' $user)' __ftf_k8s_check'
        set -a binds (string replace -- ' --preset ' ' ' $preset)' __ftf_k8s_check'
        set -a __ftf_k8s_copies (string replace -r -- $head'(\S+).*' "$mode \$1" $preset)
    end
    # The listing is quoted for re-sourcing; one eval parses it all at once.
    eval (string join \n -- $binds | string collect)
end

# fish only reflows on a resize; rerun the prompt so its width-based shortening follows.
function __ftf_on_resize --on-variable COLUMNS
    # `COLUMNS=40 cmd` fires this with its exported local both set and restored.
    set -ql COLUMNS; and return
    test "$COLUMNS" = "$__ftf_cols"; and return
    # A pill repaint queued alongside would otherwise replay the old width.
    set -e __ftf_replay_left
    commandline -f repaint
end

bind ctrl-s __ftf_stash
bind ctrl-z __ftf_fg

# Replace fish's "Job N has stopped" notice with one muted hint; other notices keep the default wording.
functions -q __ftf_default_job_summary
or functions -c fish_job_summary __ftf_default_job_summary
function fish_job_summary -a job_id is_foreground cmd_line signal_or_end_name
    if test "$signal_or_end_name" = STOPPED
        set -g __ftf_job_stopped
        set -g __ftf_job_stash $job_id
        set -l name (string split -f1 ' ' -- $cmd_line)
        # Claude Code always prints a blank line and two suspend notices; wipe them (assumes no line wrap).
        test "$name" = claude
        and printf '\e[3A\e[J' >&2
        set_color brblack >&2
        echo "⏸ $name suspended · ctrl+z or fg to return" >&2
        set_color normal >&2
        return
    end
    __ftf_default_job_summary $argv
end
