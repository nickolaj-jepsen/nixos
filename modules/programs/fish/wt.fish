# `wt new` and `wt cd` print a worktree path on stdout; wrap the command so an
# interactive shell cd's into it. Every other verb (and any failure — nothing is
# printed, so $dir is empty) passes straight through to the binary untouched.
function wt -d "git worktree manager (cd's on new / cd)"
    if contains -- "$argv[1]" new cd
        set -l dir (command wt $argv)
        set -l rc $status
        if test $rc -eq 0; and test -d "$dir"
            cd $dir
        end
        return $rc
    end
    command wt $argv
end

# Names come from the binary, which owns the layout and discovery; a duplicate
# scan here would drift from it.
function __wt_names
    command wt list --name 2>/dev/null
end

complete -c wt -f

complete -c wt -n __fish_use_subcommand -a new -d 'Start a worktree, or reopen a closed one'
complete -c wt -n __fish_use_subcommand -a land -d 'Land in the default branch, then close'
complete -c wt -n __fish_use_subcommand -a close -d 'Remove the folder, keep the work on the branch'
complete -c wt -n __fish_use_subcommand -a drop -d 'Throw a worktree and its branch away'
complete -c wt -n __fish_use_subcommand -a list -d 'List worktrees, open and closed'
complete -c wt -n __fish_use_subcommand -a cd -d 'cd into an open worktree'

complete -c wt -n '__fish_seen_subcommand_from land' -l dry-run -d 'Say what would happen'
complete -c wt -n '__fish_seen_subcommand_from land' -l abort-on-conflict -d 'Abort the rebase on conflict instead of pausing'
complete -c wt -n '__fish_seen_subcommand_from land' -l continue -d 'Continue a paused rebase'
complete -c wt -n '__fish_seen_subcommand_from land' -l abort -d 'Abort a paused rebase'
complete -c wt -n '__fish_seen_subcommand_from land' -l draft -d 'Open a draft PR'
complete -c wt -n '__fish_seen_subcommand_from land' -l pr -d 'Open a PR ready for review'
complete -c wt -n '__fish_seen_subcommand_from land' -l green -d 'Open a PR and merge it on green'
complete -c wt -n '__fish_seen_subcommand_from close' -l when-free -d 'Close once nothing works inside'
complete -c wt -n '__fish_seen_subcommand_from cd' -l main -d 'The primary checkout'
complete -c wt -n '__fish_seen_subcommand_from list' -l all -d 'Every repository under the root'
complete -c wt -n '__fish_seen_subcommand_from list' -l json -d 'JSON output'
complete -c wt -n '__fish_seen_subcommand_from list' -l name -d 'Names only'

complete -c wt -n '__fish_seen_subcommand_from new land close drop list cd' \
    -a '(__wt_names)' -d Worktree
