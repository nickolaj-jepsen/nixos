function __ftf_jobs -d 'Print "running <name>" or "stopped <name>" per job'
    set -l groups (jobs -g 2>/dev/null)
    set -q groups[1]; or return
    # jobs' own State column is translated text, so ask ps instead; check every pid, as a pipeline's leader may already have exited.
    set -l stopped (command ps -o pid=,stat= -p (jobs -p 2>/dev/null | string join ,) 2>/dev/null | string replace -rf '^\s*(\d+)\s+T.*' '$1')
    for g in $groups
        # A job that exits mid-loop drops out of the table, so these lookups can come back empty.
        set -l name (jobs -c $g 2>/dev/null)[1]
        set -q name[1]; or continue
        set -l state running
        for p in (jobs -p $g 2>/dev/null)
            contains -- $p $stopped; and set state stopped
        end
        echo $state $name
    end
end
