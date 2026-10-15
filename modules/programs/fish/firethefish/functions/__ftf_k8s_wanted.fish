function __ftf_k8s_wanted -d 'Succeed when the commandline starts with a kubernetes tool'
    string match -qr '^\s*(kubectl|kubecolor|helm|helmfile|k9s|kubectx|kubens|kns|stern)(\s|$)' -- (commandline -b 2>/dev/null)[1]
end
