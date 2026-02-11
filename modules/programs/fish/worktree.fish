set -g __worktree_dir "$HOME/dev/worktrees"

function worktree -d "Manage git worktrees"
    mkdir -p $__worktree_dir

    if test (count $argv) -eq 0
        __worktree_select
    else if test "$argv[1]" = add -a (count $argv) -eq 2
        __worktree_add $argv[2]
    else if test "$argv[1]" = root -a (count $argv) -eq 1
        __worktree_root
    else
        echo "Usage: worktree              # select worktree with fzf"
        echo "       worktree add <name>   # create worktree for current repo"
        echo "       worktree root         # return to root repo"
        return 1
    end
end

function __worktree_select
    set -l list_cmd "find $__worktree_dir -mindepth 2 -maxdepth 2 -type d -printf '%T@\\t%P\\n' | sort -rn | awk -F'\\t' '{age=systime()-int(\$1); if(age<60)t=age\"s\"; else if(age<3600)t=int(age/60)\"m\"; else if(age<86400)t=int(age/3600)\"h\"; else t=int(age/86400)\"d\"; printf \"%s\\t%s\\n\",\$2,t}'"

    while true
        set -l entries (sh -c "$list_cmd")

        if test -z "$entries"
            echo "No worktrees found in $__worktree_dir"
            return 0
        end

        set -l result (printf '%s\n' $entries | fzf \
            --delimiter='\t' \
            --with-nth=1.. \
            --tabstop=45 \
            --prompt="Worktree > " \
            --height=50% \
            --layout=reverse \
            --footer="delete: remove worktree" \
            --expect=delete)

        if test (count $result) -lt 2
            return 0
        end

        set -l key $result[1]
        set -l path (string split \t $result[2])[1]

        if test "$key" = delete
            git worktree remove --force "$__worktree_dir/$path" 2>/dev/null
            rm -df "$__worktree_dir/"(dirname "$path") 2>/dev/null
        else
            cd "$__worktree_dir/$path"
            return 0
        end
    end
end

function __worktree_add -a name
    set -l toplevel (git rev-parse --show-toplevel 2>/dev/null)
    or begin
        echo "Not inside a git repository"
        return 1
    end

    set -l repo (basename $toplevel)
    set -l dest "$__worktree_dir/$repo/$name"

    if git show-ref --verify --quiet "refs/heads/$name"
        git worktree add "$dest" "$name"
    else
        git worktree add -b "$name" "$dest"
    end

    and cd "$dest"
end

complete -c worktree -f
complete -c worktree -n __fish_use_subcommand -a add -d 'Create a new worktree'
complete -c worktree -n __fish_use_subcommand -a root -d 'Return to root repo'
complete -c worktree -n '__fish_seen_subcommand_from add' -a '(__worktree_complete_branches)' -d 'Branch name'

function __worktree_complete_branches
    git branch --format='%(refname:short)' 2>/dev/null
end

function __worktree_root
    set -l toplevel (git rev-parse --show-toplevel 2>/dev/null)
    or begin
        echo "Not inside a git repository"
        return 1
    end

    set -l common_dir (git rev-parse --git-common-dir 2>/dev/null)
    set -l git_dir (git rev-parse --git-dir 2>/dev/null)

    if test "$common_dir" != .git -a "$common_dir" != "$git_dir"
        cd (dirname $common_dir)
    else
        cd $toplevel
    end
end
