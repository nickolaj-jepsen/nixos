function __ftf_stash_pop -d 'Put the stashed line back on the commandline'
    set -q __ftf_stash[1]; or return
    commandline -r -- $__ftf_stash
    commandline -C $__ftf_stash_cursor
    set -e __ftf_stash
    set -e __ftf_stash_cursor
end
