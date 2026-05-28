function __claude_wt_names
    set -l main_wt (git worktree list --porcelain 2>/dev/null | awk '/^worktree / {print $2; exit}')
    test -n "$main_wt"; or return
    set -l wt_dir "$main_wt/.claude/worktrees"
    test -d "$wt_dir"; or return
    for d in $wt_dir/*/
        basename $d
    end
end

complete -c claude-wt -f

complete -c claude-wt -n __fish_use_subcommand -a list   -d 'List Claude worktrees'
complete -c claude-wt -n __fish_use_subcommand -a clean  -d 'Remove safely-removable worktrees'
complete -c claude-wt -n __fish_use_subcommand -a apply  -d 'Rebase branch onto default and remove worktree'
complete -c claude-wt -n __fish_use_subcommand -a smerge -d 'Open worktree in Sublime Merge'

complete -c claude-wt -n '__fish_seen_subcommand_from clean' -l dry-run -d 'Show what would be removed'
complete -c claude-wt -n '__fish_seen_subcommand_from apply' -l dry-run -d 'Show what would be done'

complete -c claude-wt -n '__fish_seen_subcommand_from clean apply smerge' \
    -a '(__claude_wt_names)' -d Worktree
