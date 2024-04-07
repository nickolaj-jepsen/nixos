if type -q nvim
    alias vim nvim
end

if type -q docker
    abbr d "docker"
end

if type -q docker-compose
    abbr dc "docker-compose"
end

if type -q snap
    set PYCHARM_SNAP (snap list | grep 'pycharm' | awk '{ print $1 }')
    set HELM_SNAP (snap list | grep 'helm' | awk '{ print $1 }')
    if test -n "$HELM_SNAP"
        alias helm "snap run $HELM_SNAP"
    end
    if test -n "$PYCHARM_SNAP"
        alias pycharm "snap run $PYCHARM_SNAP"
    end
end

if type -q to
    abbr z "to"
end

if type -q broot
    abbr br "broot"
end

if type -q terraform
    abbr tf "terraform"
    abbr tfp "terraform plan"
    abbr tfa "terraform apply"
    abbr tfi "terraform init"
end