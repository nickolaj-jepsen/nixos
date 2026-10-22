function __ftf_job_unstash -a line -d 'Foreground the stashed job once the command that took the terminal is done'
    # Suspending a job raises fish_postexec too, with the flag set; that one leaves it stashed.
    set -q __ftf_job_stopped; and return
    set -q __ftf_job_stash[1]; or return
    # These end or replace the shell; a job foregrounded into that is left without one.
    string match -qr '^\s*(?:exit|logout|exec)\b' -- $line; and return
    set -l job $__ftf_job_stash
    # Dropped rather than kept: a job resumed with bg, or killed, is not the stash any more.
    set -e __ftf_job_stash
    __ftf_job_is_stopped $job; or return
    fg %$job 2>/dev/null
    commandline -f repaint
end
