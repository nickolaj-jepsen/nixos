function __ftf_stash_pop
    set -q __ftf_stash[1]; or return
    commandline -r -- $__ftf_stash[-1]
    commandline -C $__ftf_stash_cursor[-1]
    set -e __ftf_stash[-1]
    set -e __ftf_stash_cursor[-1]
end
