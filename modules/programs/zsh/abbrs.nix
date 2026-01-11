{lib, ...}: let
  kube_verbs = [
    {
      s = "g";
      v = "get";
    }
    {
      s = "d";
      v = "describe";
    }
    {
      s = "rm";
      v = "delete";
    }
    {
      s = "e";
      v = "edit";
    }
  ];
  kube_resources = [
    {
      s = "p";
      r = "pods";
    }
    {
      s = "d";
      r = "deployments";
    }
    {
      s = "s";
      r = "services";
    }
    {
      s = "i";
      r = "ingresses";
    }
    {
      s = "c";
      r = "configmaps";
    }
    {
      s = "ds";
      r = "daemonsets";
    }
    {
      s = "ss";
      r = "statefulsets";
    }
    {
      s = "n";
      r = "namespace";
    }
    {
      s = "ns";
      r = "namespace";
    }
  ];

  # Generate dynamic k8s abbreviations
  kube_abbrs = lib.listToAttrs (
    lib.concatMap (verb:
      [
        {
          name = "k${verb.s}";
          value = "kubectl ${verb.v}";
        }
      ]
      ++ (map (res: {
          name = "k${verb.s}${res.s}";
          value = "kubectl ${verb.v} ${res.r}";
        })
        kube_resources))
    kube_verbs
  );

  static_kube_abbrs = {
    k = "kubectl";
    kl = "kubectl logs -f";
    kgl = "kubectl logs -f";
    kaf = "kubectl apply -f";
    kr = "kubectl rollout";
    krs = "kubectl rollout status";
    krr = "kubectl rollout restart";
    kt = "kubectl top";
    ktp = "kubectl top pods";
    ktn = "kubectl top nodes";
    kpf = "kubectl port-forward";
    kfp = "kubectl port-forward";
    ksns = "kubectl config set-context --current --namespace";
    ksc = "kubectl config set-context";
  };

  general_abbrs = {
    # General
    gs = "git status";
    gc = "git commit";
    gp = "git push";
    gl = "git pull";
    gco = "git checkout";
    gd = "git diff";
    ll = "ls -la";
  };
in
  general_abbrs // static_kube_abbrs // kube_abbrs
