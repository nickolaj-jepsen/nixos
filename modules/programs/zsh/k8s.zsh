# Kubernetes functions and completion (migrated from fish)

if command -v kubectl &> /dev/null; then
  # Namespace functions
  kns() {
    kubectl config view --minify --output 'jsonpath={..namespace}'
  }

  # kexec function (equivalent to fish __echo_kubeexec)
  kexec() {
    local _flag_namespace
    _flag_namespace=$(kubectl config view --minify --output 'jsonpath={..namespace}')
    if [[ -z "$_flag_namespace" ]]; then
      _flag_namespace="default"
    fi

    local _flag_pod="shop"
    local POD
    POD=$(kubectl get pods --namespace "$_flag_namespace" 2>/dev/null | grep "^$_flag_pod" | grep Running | head -n1 | awk '{ print $1 }')

    if [[ -z "$POD" ]]; then
      echo "kubectl exec --namespace $_flag_namespace -it"
      return
    fi
    echo "kubectl exec --namespace $_flag_namespace -it $POD --"
  }

  # kmanage function (equivalent to fish __echo_kubemanage)
  kmanage() {
    local _flag_namespace
    _flag_namespace=$(kubectl config view --minify --output 'jsonpath={..namespace}')
    if [[ -z "$_flag_namespace" ]]; then
      _flag_namespace="default"
    fi

    local _flag_pod="shop"
    local POD
    POD=$(kubectl get pods --namespace "$_flag_namespace" 2>/dev/null | grep "^$_flag_pod" | grep Running | head -n1 | awk '{ print $1 }')

    if [[ -z "$POD" ]]; then
      echo "kubectl exec --namespace $_flag_namespace -it"
      return
    fi
    echo "kubectl exec --namespace $_flag_namespace -it $POD -- python3 /src/lib/manage.py"
  }

  # Kubectl completion
  source <(kubectl completion zsh)
fi
