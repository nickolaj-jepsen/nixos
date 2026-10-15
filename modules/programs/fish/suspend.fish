# Ctrl+Z at the prompt resumes the last job, so Ctrl+Z toggles a program in and out (programs already suspend on it).
function __fg_last_job
    jobs -q; or return
    fg 2>/dev/null
    commandline -f repaint
end

# Wraps the current right prompt, so stashed text and stopped jobs show side by side.
functions -q fish_right_prompt
and functions -c fish_right_prompt __suspend_inner_right_prompt
function fish_right_prompt
    set -l stopped (jobs | string replace -rf '^\d+\t\d+\t\S+\tstopped\t(\S+).*' '$1')
    if set -q stopped[1]
        set_color cyan
        echo -n "⏸ $stopped "
        set_color normal
    end
    functions -q __suspend_inner_right_prompt
    and __suspend_inner_right_prompt
end

# Replace fish's "Job N has stopped" notice with one muted hint; other notices keep the default wording.
functions -q fish_job_summary
and functions -c fish_job_summary __fish_default_job_summary
function fish_job_summary --argument-names job_id is_foreground cmd_line signal_or_end_name
    if test "$signal_or_end_name" = STOPPED
        set -l name (string split -f1 ' ' -- $cmd_line)
        # Claude Code always prints a blank line and two suspend notices; wipe them (assumes no line wrap).
        test "$name" = claude
        and printf '\e[3A\e[J' >&2
        set_color brblack
        echo "⏸ $name suspended · ctrl+z or fg to return" >&2
        set_color normal
        return
    end
    __fish_default_job_summary $argv
end

bind ctrl-z __fg_last_job
