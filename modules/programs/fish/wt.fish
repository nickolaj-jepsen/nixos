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

function __wt_names
    set -l main (git worktree list --porcelain 2>/dev/null | awk '/^worktree / {print $2; exit}')
    test -n "$main"; or return

    begin
        # Every registered worktree (anywhere), main included.
        git worktree list --porcelain 2>/dev/null | awk '/^worktree / {print $2}'
        # Plus orphan dirs under .claude/worktrees/ git no longer tracks.
        set -l wt_dir "$main/.claude/worktrees"
        if test -d "$wt_dir"
            for d in $wt_dir/*/
                test -d "$d"; and echo $d
            end
        end
    end | while read -l p
        basename $p
    end | sort -u
end

complete -c wt -f

complete -c wt -n __fish_use_subcommand -a list -d 'List worktrees'
complete -c wt -n __fish_use_subcommand -a create -d 'Create a worktree on a new branch under .claude/worktrees'
complete -c wt -n __fish_use_subcommand -a cd -d 'cd into a worktree (fzf picker if no name)'
complete -c wt -n __fish_use_subcommand -a clean -d 'Remove safely-removable worktrees'
complete -c wt -n __fish_use_subcommand -a apply -d 'Land branch: rebase, ff default, delete branch'
complete -c wt -n __fish_use_subcommand -a diff -d 'Review a worktree diff (committed + uncommitted) in diffnav'
complete -c wt -n __fish_use_subcommand -a smerge -d 'Open worktree in Sublime Merge'
complete -c wt -n __fish_use_subcommand -a code -d 'Open worktree in VS Code'

complete -c wt -n '__fish_seen_subcommand_from clean' -l dry-run -d 'Show what would be removed'
complete -c wt -n '__fish_seen_subcommand_from apply' -l dry-run -d 'Show what would be done'

complete -c wt -n '__fish_seen_subcommand_from clean apply diff smerge code cd' \
    -a '(__wt_names)' -d Worktree
