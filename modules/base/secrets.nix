let
  # Root decrypts via the host key; HM-side via ~/.ssh/id_ed25519. On darwin the
  # host key must exist first (`sudo ssh-keygen -A`).
  secretsModule = {
    config,
    fpLib,
    ...
  }: {
    age.identityPaths = ["/etc/ssh/ssh_host_ed25519_key"];
    age.rekey = fpLib.mkAgenixRekey {
      inherit (config.fireproof) hostname;
      store = ".rekey";
    };
  };
in {
  flake.modules.nixos.secrets = secretsModule;
  # agenix-rekey auto-discovers darwinConfigurations, so the Mac rekeys like any nixos host.
  flake.modules.darwin.secrets = secretsModule;
}
