function __ftf_fg -d 'Resume the stashed job; with none, pop the stash on an empty line or undo'
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
    set -l job $__ftf_job_stash
    set -e __ftf_job_stash
    # The stash is one slot, but fish keeps every stopped job; fg without a job would pick a newer one.
    if set -q job[1]; and __ftf_job_is_stopped $job
        fg %$job 2>/dev/null
    else
        fg 2>/dev/null
    end
    commandline -f repaint
end
