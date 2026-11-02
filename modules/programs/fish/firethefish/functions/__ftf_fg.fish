function __ftf_fg -d 'Resume the stashed job or else the newest stopped one; with none, pop the stash on an empty line or undo'
    set -l stash $__ftf_job_stash
    set -e __ftf_job_stash
    # The stash is one slot, but fish keeps every stopped job; running jobs stay in the background.
    for job in $stash (jobs | string replace -rf '^(\d+)\t.*' '$1')
        if __ftf_job_is_stopped $job
            # fg takes a pid, not %job; any of the job's pids identifies it.
            fg (jobs -p %$job)[1] 2>/dev/null
            commandline -f repaint
            return
        end
    end
    # Undoing a stash push would restore the line but leave the entry to be popped again.
    if test -z "$(commandline)"; and set -q __ftf_stash[1]
        __ftf_stash_pop
        commandline -f repaint
    else
        commandline -f undo
    end
end
