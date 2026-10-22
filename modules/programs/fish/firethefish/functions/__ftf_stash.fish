function __ftf_stash -d 'Swap the commandline with the stashed line, or restore it when the line is empty'
    if commandline --paging-mode
        commandline -f pager-toggle-search
        return
    end
    set -l buf (commandline | string collect)
    if test -z "$buf"
        __ftf_stash_pop
    else
        # One slot, swapped: a second stash takes the old line back instead of stacking on it.
        set -l old $__ftf_stash
        set -l old_cursor $__ftf_stash_cursor
        set -g __ftf_stash $buf
        set -g __ftf_stash_cursor (commandline -C)
        if set -q old[1]
            commandline -r -- $old
            commandline -C $old_cursor
        else
            commandline -r ''
        end
    end
    commandline -f repaint
end
