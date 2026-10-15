function __ftf_fg -d 'Resume the most recent job; with none, pop the stash on an empty line or undo'
    if not jobs -q
        # Undoing a stash push would restore the line but leave the entry to be popped again.
        if test -z "$(commandline)"; and set -q __ftf_stash[1]
            __ftf_stash_pop
            commandline -f repaint
        else
            commandline -f undo
        end
        return
    end
    fg 2>/dev/null
    commandline -f repaint
end
