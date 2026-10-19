function __ftf_in_repo -a dir -d 'Succeed when GIT_DIR is set (printing nothing) or dir or one of its parents contains .git (printing that .git path)'
    set -q GIT_DIR; and return
    while true
        test -e $dir/.git; and echo $dir/.git; and return
        test $dir = /; and return 1
        set dir (path dirname -- $dir)
    end
end
