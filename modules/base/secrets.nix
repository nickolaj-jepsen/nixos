{
  flake.modules.nixos.secrets = {
    config,
    fpLib,
    ...
  }: {
    # Root decrypts via the host key; user secrets decrypt HM-side via ~/.ssh/id_ed25519.
    age.identityPaths = ["/etc/ssh/ssh_host_ed25519_key"];
    age.rekey = fpLib.mkAgenixRekey {
      inherit (config.fireproof) hostname;
      store = ".rekey";
    };
  };
}
