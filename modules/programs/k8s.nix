# kubectl + the AO kube configs. Home-manager half only: the secrets decrypt
# HM-side via ~/.ssh/id_ed25519 (see modules/base/hm-secrets.nix). Selected on dev hosts.
{
  flake.modules.homeManager.k8s = {
    config,
    lib,
    pkgs,
    ...
  }: let
    inherit (config.home) homeDirectory;
  in {
    config = lib.mkIf config.fireproof.dev.k8s.enable {
      home.packages = [
        pkgs.kubectl
        (pkgs.writeShellApplication {
          name = "kctx";
          runtimeInputs = [pkgs.kubectl pkgs.fzf];
          text = ''
            CONTEXTS=$(kubectl config get-contexts -o name)

            if [ -z "$CONTEXTS" ]; then
                echo "No kubernetes contexts found"
                exit 1
            fi

            SELECTED=$(echo "$CONTEXTS" | fzf --prompt="Kube Context > " --height=20% --layout=reverse)

            if [ -n "$SELECTED" ]; then
                kubectl config use-context "$SELECTED"
                echo "Switched to context: $SELECTED"
            fi
          '';
        })
      ];

      age.secrets.k8s-ao-dev = {
        rekeyFile = ../../secrets/k8s/ao-dev.age;
        path = "${homeDirectory}/.kube/config.ao-dev";
        mode = "0600";
      };

      age.secrets.k8s-ao-prod = {
        rekeyFile = ../../secrets/k8s/ao-prod.age;
        path = "${homeDirectory}/.kube/config.ao-prod";
        mode = "0600";
      };

      home.sessionVariables.KUBECONFIG = "${config.age.secrets.k8s-ao-dev.path}:${config.age.secrets.k8s-ao-prod.path}:$HOME/.kube/config";
    };
  };
}
