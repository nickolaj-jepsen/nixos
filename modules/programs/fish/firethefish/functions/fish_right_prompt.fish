# Pill drawing mirrors bobthefish's segments (MIT, Copyright (c) 2013-2021 Justin Hileman).

function fish_right_prompt
    contains -- --final-rendering $argv; and return
    test "$TERM" = dumb; and return
    set -g __ftf_rbg
    set -l pills (
        begin
            __ftf_right_k8s
            __ftf_right_stash
            __ftf_right_jobs
        end | string collect
    )
    set -l duration (__ftf_duration)
    if set -q duration[1]
        test $CMD_DURATION -ge 60000; and set_color brred; or set_color brblack
        echo -n $duration
        test -n "$pills"; and echo -n ' '
    end
    printf %s $pills
    set_color normal
end

function __ftf_pill -a bg fg
    set_color normal
    switch "$__ftf_rbg"
        case ''
            set_color $bg
            echo -n \uE0B2
        case $bg
            set_color -b $bg $fg $argv[3..]
            echo -n \uE0B3
        case '*'
            set_color $bg -b $__ftf_rbg
            echo -n \uE0B2
    end
    set_color -b $bg $fg $argv[3..]
    echo -n ' '
    set -g __ftf_rbg $bg
end

function __ftf_duration
    test "$__ftf_fresh" = 1; and test "$CMD_DURATION" -ge 3000; or return
    set -l s (math "floor($CMD_DURATION / 1000)")
    if test $s -lt 60
        echo {$s}s
    else if test $s -lt 3600
        printf '%dm%02ds\n' (math "floor($s / 60)") (math $s % 60)
    else
        printf '%dh%02dm\n' (math "floor($s / 3600)") (math "floor($s % 3600 / 60)")
    end
end

function __ftf_right_k8s
    set -g __ftf_k8s_shown 0
    set -g __ftf_k8s_dev 0
    set -l ctx (__ftf_k8s_context)
    set -q ctx[1]; or return
    if string match -qi '*prod*' -- $ctx[1]
        __ftf_pill red white --bold
    else
        set __ftf_k8s_dev 1
        __ftf_k8s_wanted; or return
        set __ftf_k8s_shown 1
        __ftf_pill magenta white --bold
    end
    set -l label $ctx[1]
    test -n "$ctx[2]" -a "$ctx[2]" != default; and set label $label:$ctx[2]
    echo -n "⎈ $label "
end

function __ftf_right_stash
    set -q __ftf_stash[1]; or return
    __ftf_pill yellow black
    echo -n \uF0EA (string replace -a \n ' ⏎ ' -- $__ftf_stash | string shorten -m 24)
    echo -n ' '
end

function __ftf_right_jobs
    set -l stopped (string replace -rf '^stopped ' '' -- $__ftf_job_states)
    set -q stopped[1]; or return
    __ftf_pill blue black
    echo -n "⏸ $stopped "
end

function __ftf_k8s_context -d 'Print the current kube context and its namespace, parsed from the kubeconfig files'
    set -l files ~/.kube/config
    test -n "$KUBECONFIG"; and set files (string split : -- $KUBECONFIG)
    set files (path filter -f -- $files)
    set -q files[1]; or return
    set -l key "$files" (path mtime -- $files)
    if test "$key" != "$__ftf_k8s_key"
        set -g __ftf_k8s_key "$key"
        set -g __ftf_k8s (__ftf_k8s_parse $files)
        # mtime has 1s resolution, so a file written in the last second may change again under the same key.
        for age in (path mtime -R -- $files)
            test $age -lt 2; and set __ftf_k8s_key
        end
    end
    string join \n -- $__ftf_k8s
end

function __ftf_k8s_parse
    set -l ctx
    for f in $argv
        set ctx (string replace -rf '^current-context:\s*["\']?([^"\'\s]+)["\']?\s*$' '$1' <$f)[1]
        test -n "$ctx"; and break
    end
    test -n "$ctx"; or return
    # The first file defining the context wins, as in kubectl; assumes kubectl's layout with list items at column 0.
    for f in $argv
        set -l section
        set -l name
        set -l ns
        for line in (string trim -r <$f) eof:
            if string match -qr '^(- |\S)' -- $line
                if test "$section" = contexts -a "$name" = "$ctx"
                    printf '%s\n' $ctx $ns
                    return
                end
                set name
                set ns
                string match -qr '^[^-\s]' -- $line
                and set section (string split -f1 : -- $line)
            end
            test "$section" = contexts; or continue
            set -l v (string replace -rf '^(?:- |  )name:\s*(.*)$' '$1' -- $line)
            and set name (string trim -c '"\'' -- $v)
            set v (string replace -rf '^\s+namespace:\s*(.*)$' '$1' -- $line)
            and set ns (string trim -c '"\'' -- $v)
        end
    end
    echo $ctx
end
