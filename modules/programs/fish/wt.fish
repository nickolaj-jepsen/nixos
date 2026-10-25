# `wt create` and `wt cd` print a worktree path on stdout; wrap the command so an
# interactive shell cd's into it. Every other verb (and any failure — nothing is
# printed, so $dir is empty) passes straight through to the binary untouched.
function wt -d "git worktree manager (cd's on create / cd)"
    if contains -- "$argv[1]" create cd
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
    command wt names 2>/dev/null
end

complete -c wt -f

complete -c wt -n __fish_use_subcommand -a list -d 'List worktrees'
complete -c wt -n __fish_use_subcommand -a status -d 'Machine-readable JSON status'
complete -c wt -n __fish_use_subcommand -a create -d 'Create a worktree under <root>/<repo> on a new branch'
complete -c wt -n __fish_use_subcommand -a cd -d 'cd into a worktree (fzf picker if no name)'
complete -c wt -n __fish_use_subcommand -a clean -d 'Remove worktrees with nothing left to lose'
complete -c wt -n __fish_use_subcommand -a remove -d 'Remove one worktree, archiving forced work'
complete -c wt -n __fish_use_subcommand -a trash -d 'List or purge archived work'
complete -c wt -n __fish_use_subcommand -a restore -d 'Restore archived work'
complete -c wt -n __fish_use_subcommand -a apply -d 'Land a branch: rebase, ff default, keep the worktree'
complete -c wt -n __fish_use_subcommand -a sync -d 'Rebase a worktree onto local default'
complete -c wt -n __fish_use_subcommand -a diff -d 'Review a worktree diff (diffnav, or --stat)'
complete -c wt -n __fish_use_subcommand -a smerge -d 'Open worktree in Sublime Merge'
complete -c wt -n __fish_use_subcommand -a code -d 'Open worktree in VS Code'
complete -c wt -n __fish_use_subcommand -a migrate -d 'Move this repo\'s worktrees outside the root into it'
complete -c wt -n __fish_use_subcommand -a names -d 'Print every worktree name'

complete -c wt -n '__fish_seen_subcommand_from clean remove apply sync' -l dry-run -d 'Show what would be done'
complete -c wt -n '__fish_seen_subcommand_from remove' -l force -d 'Archive dirty or unlanded work and remove anyway'
complete -c wt -n '__fish_seen_subcommand_from remove' -l ignore-in-use -d 'Remove despite a live process inside'
complete -c wt -n '__fish_seen_subcommand_from apply sync' -l abort-on-conflict -d 'Abort the rebase on conflict instead of pausing'
complete -c wt -n '__fish_seen_subcommand_from apply sync' -l continue -d 'Continue a paused rebase'
complete -c wt -n '__fish_seen_subcommand_from apply sync' -l abort -d 'Abort a paused rebase'
complete -c wt -n '__fish_seen_subcommand_from apply' -l remove -d 'Also delete the worktree and branch once landed'
complete -c wt -n '__fish_seen_subcommand_from cd' -l main -d 'The primary checkout'
complete -c wt -n '__fish_seen_subcommand_from trash' -l json -d 'JSON output'
complete -c wt -n '__fish_seen_subcommand_from trash' -l all -d 'Every repository / every entry'
complete -c wt -n '__fish_seen_subcommand_from list status' -l all -d 'Every repository under the root'
complete -c wt -n '__fish_seen_subcommand_from restore' -l name -d 'New worktree and branch name'

complete -c wt -n '__fish_seen_subcommand_from remove apply sync diff smerge code cd' \
    -a '(__wt_names)' -d Worktree
