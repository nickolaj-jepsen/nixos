function __ftf_stash -d 'Push the commandline onto the stash stack, or pop it when the line is empty'
    if commandline --paging-mode
        commandline -f pager-toggle-search
        return
    end
    set -l buf (commandline | string collect)
    if test -n "$buf"
        set -ga __ftf_stash $buf
        set -ga __ftf_stash_cursor (commandline -C)
        commandline -r ''
    else
        __ftf_stash_pop
    end
    commandline -f repaint
end
