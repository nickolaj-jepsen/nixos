function __ftf_job_is_stopped -a job -d 'Whether job $job has a stopped process'
    # A pipeline's leader may already have exited, so any stopped pid counts.
    for p in (jobs -p %$job 2>/dev/null)
        command ps -o stat= -p $p 2>/dev/null | string match -qr '^\s*T'; and return 0
    end
    return 1
end
