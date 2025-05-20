set __kube_verbs get describe delete edit
set __kube_verbs_short g d rm e
set __kube_resource pods deployments services ingresses configmaps daemonsets statefulsets namespace namespace
set __kube_resource_short p d s i c ds ss n ns

function __echo_kubeexec
    set _flag_namespace (kubectl config view --minify --output 'jsonpath={..namespace}')
    if test -z "$_flag_namespace"
        set _flag_namespace default
    end

    set _flag_pod shop
    set POD (kubectl get pods --namespace $_flag_namespace 2>/dev/null | grep "^$_flag_pod" | grep Running | head -n1 | awk '{ print $1 }')
    if test -z "$POD"
        echo "kubectl exec --namespace $_flag_namespace -it"
        return
    end
    echo "kubectl exec --namespace $_flag_namespace -it $POD --"
end

function __echo_kubemanage
    set _flag_namespace (kubectl config view --minify --output 'jsonpath={..namespace}')
    if test -z "$_flag_namespace"
        set _flag_namespace default
    end

    set _flag_pod shop
    set POD (kubectl get pods --namespace $_flag_namespace 2>/dev/null | grep "^$_flag_pod" | grep Running | head -n1 | awk '{ print $1 }')
    if test -z "$POD"
        echo "kubectl exec --namespace $_flag_namespace -it"
        return
    end
    echo "kubectl exec --namespace $_flag_namespace -it $POD -- python3 /src/lib/manage.py"
end

if type -q kubectl
    for verb_index in (seq (count $__kube_verbs))
        abbr "k$__kube_verbs_short[$verb_index]" "kubectl $__kube_verbs[$verb_index]"
        for res_index in (seq (count $__kube_resource))
            abbr "k$__kube_verbs_short[$verb_index]$__kube_resource_short[$res_index]" "kubectl $__kube_verbs[$verb_index] $__kube_resource[$res_index]"
        end
    end

    abbr k kubectl
    abbr kl kubectl logs -f
    abbr kgl kubectl logs -f
    abbr kaf kubectl apply -f
    abbr kr kubectl rollout
    abbr krs kubectl rollout status
    abbr krr kubectl rollout restart
    abbr kt kubectl top
    abbr ktp kubectl top pods
    abbr ktn kubectl top nodes
    abbr kpf kubectl port-forward
    abbr kfp kubectl port-forward

    alias kns "kubectl config view --minify --output 'jsonpath={..namespace}'"
    abbr ksns "kubectl config set-context --current --namespace"
    abbr ksc "kubectl config set-context"

    abbr kexec --function __echo_kubeexec
    abbr kmanage --function __echo_kubemanage
end
