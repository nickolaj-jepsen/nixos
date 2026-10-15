# Ctrl+S stashes the commandline and restores it at the next prompt (like Claude Code's prompt stash).
function __stash_commandline
    # Keep fish's default ctrl-s (search inside the completion pager)
    if commandline --paging-mode
        commandline -f pager-toggle-search
        return
    end
    set -l buf (commandline | string collect)
    if test -n "$buf"
        set -g __stashed_commandline $buf
        set -g __stashed_cursor (commandline -C)
        commandline -r ''
        commandline -f repaint
    else if set -q __stashed_commandline
        __restore_stash
        commandline -f repaint
    end
end

function __restore_stash --on-event fish_prompt
    set -q __stashed_commandline; or return
    commandline -r -- $__stashed_commandline
    commandline -C $__stashed_cursor
    set -e __stashed_commandline __stashed_cursor
end

# Wrap whatever right prompt the theme defines; must run after plugins are on fish_function_path.
functions -q fish_right_prompt
and functions -c fish_right_prompt __stash_theme_right_prompt
function fish_right_prompt
    if set -q __stashed_commandline
        set_color yellow
        echo -n "⏸ "(string replace -a \n ' ⏎ ' -- $__stashed_commandline | string shorten -m 24)' '
        set_color normal
    end
    functions -q __stash_theme_right_prompt
    and __stash_theme_right_prompt
end

bind ctrl-s __stash_commandline
