function fish_greeting
    set -l now
    set -l up
    if test -r /proc/uptime
        set up (math "floor("(string split -f1 ' ' </proc/uptime)")")
        set now (math $up + (string replace -rf '^btime ' '' </proc/stat))
    else
        set now (command date +%s)
        set up (math $now - (command sysctl -n kern.boottime | string match -rg 'sec = (\d+)'))
    end

    set -l line (prompt_hostname)
    if test -r /proc/sys/kernel/osrelease
        set -a line (string trim </proc/sys/kernel/osrelease)
    else
        set -a line (command uname -r)
    end
    set -a line "up "(__ftf_ago $up)

    if test -e /etc/NIXOS
        set -l current (path resolve /run/current-system)
        set -l links /nix/var/nix/profiles/system-*-link
        for link in $links[-1..1]
            if test (path resolve $link) = $current
                # path mtime follows the link into the store (mtime 1); the link's own mtime is the switch time.
                set -l switched (command stat -c %Y /run/current-system)
                set -a line "gen "(string match -rg 'system-(\d+)-link' $link)", switched "(__ftf_ago (math $now - $switched))" ago"
                break
            end
        end
        set -l failed (command systemctl show -p NFailedUnits --value 2>/dev/null)
        string match -qr '^\d+$' -- "$failed"; or set failed 0
        test "$failed" -eq 1; and set -a line "1 failed unit"
        test "$failed" -gt 1; and set -a line "$failed failed units"
        # Hosts without boot.kernel.enable (WSL) have no kernel link.
        test -e /run/booted-system/kernel -a -e /run/current-system/kernel
        and test (path resolve /run/booted-system/kernel) != (path resolve /run/current-system/kernel)
        and set -a line "reboot pending"
    end

    set_color brblack
    string join ' · ' -- $line

    set -l common
    set -l real_pwd (builtin pwd -P 2>/dev/null | string collect); or set real_pwd $PWD
    __ftf_in_repo $real_pwd >/dev/null; and command -q git
    and set common (command git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
    if set -q common[1]
        set -l repo
        set -l last (command git log -1 --format=%ct%x1f%s 2>/dev/null | string split \x1f)
        set -q last[2]; and set -a repo "last commit "(__ftf_ago (math $now - $last[1]))" ago: "(string shorten -m 60 -- $last[2])
        set -l worktrees $common/worktrees/*/
        set -l n (count $worktrees)
        test $n -eq 1; and set -a repo "1 linked worktree"
        test $n -gt 1; and set -a repo "$n linked worktrees"
        set -l autostash 0
        test -f $common/logs/refs/stash; and set autostash (count (string match '*'\tautostash <$common/logs/refs/stash))
        test $autostash -eq 1; and set -a repo "1 leftover autostash"
        test $autostash -gt 1; and set -a repo "$autostash leftover autostashes"
        set -q repo[1]; and string join ' · ' -- $repo
    end
    set_color normal
end

function __ftf_ago -a secs
    # /proc-derived now lags date +%s by up to a second, so a fresh commit can look slightly in the future.
    set secs (math "max(0, $secs)")
    if test $secs -ge 86400
        echo (math "floor($secs / 86400)")d
    else if test $secs -ge 3600
        echo (math "floor($secs / 3600)")h
    else
        echo (math "floor($secs / 60)")m
    end
end
