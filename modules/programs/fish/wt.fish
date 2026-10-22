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
complete -c wt -n __fish_use_subcommand -a create -d 'Create a worktree under ~/worktrees/<repo> on a new branch'
complete -c wt -n __fish_use_subcommand -a cd -d 'cd into a worktree (fzf picker if no name)'
complete -c wt -n __fish_use_subcommand -a clean -d 'Remove safely-removable worktrees'
complete -c wt -n __fish_use_subcommand -a apply -d 'Land branch: rebase, ff default, delete branch'
complete -c wt -n __fish_use_subcommand -a diff -d 'Review a worktree diff (committed + uncommitted) in diffnav'
complete -c wt -n __fish_use_subcommand -a smerge -d 'Open worktree in Sublime Merge'
complete -c wt -n __fish_use_subcommand -a code -d 'Open worktree in VS Code'
complete -c wt -n __fish_use_subcommand -a migrate -d 'Move this repo\'s worktrees that sit outside the root into it'

complete -c wt -n '__fish_seen_subcommand_from clean' -l dry-run -d 'Show what would be removed'
complete -c wt -n '__fish_seen_subcommand_from apply migrate' -l dry-run -d 'Show what would be done'

complete -c wt -n '__fish_seen_subcommand_from clean apply diff smerge code cd' \
    -a '(__wt_names)' -d Worktree
