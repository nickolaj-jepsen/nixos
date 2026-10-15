function fish_title
    # No status current-command fallback: after ctrl-z resumes a job from a binding it keeps naming that job at the prompt.
    set -l cmd $argv[1]
    string join ' · ' -- (string shorten -N -m 24 -- $cmd) (prompt_pwd)
end
