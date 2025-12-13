# Enabled when: dev
{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (config.fireproof) username;
in {
  config = lib.mkIf config.fireproof.dev.enable {
    environment.systemPackages = [
      pkgs.kubectl
    ];

    age.secrets.k8s-ao-dev = {
      rekeyFile = ../../secrets/k8s/ao-dev.age;
      path = "/home/${username}/.kube/config.ao-dev";
      mode = "0600";
      owner = username;
    };

    age.secrets.k8s-ao-prod = {
      rekeyFile = ../../secrets/k8s/ao-prod.age;
      path = "/home/${username}/.kube/config.ao-prod";
      mode = "0600";
      owner = username;
    };

    fireproof.home-manager = {
      home.sessionVariables = {
        KUBECONFIG = "${config.age.secrets.k8s-ao-dev.path}:${config.age.secrets.k8s-ao-prod.path}:$HOME/.kube/config";
      };
    };
  };
}
