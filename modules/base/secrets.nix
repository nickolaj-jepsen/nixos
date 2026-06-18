{
  flake.modules.nixos.secrets = {
    config,
    fpLib,
    ...
  }: {
    # Root decrypts via the host key in /etc/ssh; user secrets decrypt during HM
    # activation via ~/.ssh/id_ed25519 — see the hm-secrets half.
    age.identityPaths = ["/etc/ssh/ssh_host_ed25519_key"];
    age.rekey = fpLib.mkAgenixRekey {
      inherit (config.fireproof) hostname;
      store = ".rekey";
    };
  };
}
