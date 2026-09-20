{
  inputs,
  fpLib,
  ...
}: let
  # Root decrypts via the host key; HM-side via ~/.ssh/id_ed25519. On darwin the
  # host key must exist first (`sudo ssh-keygen -A`).
  secretsModule = class: {config, ...}: {
    imports = [
      inputs.agenix."${class}Modules".default
      inputs.agenix-rekey."${class}Modules".default
    ];
    age.identityPaths = ["/etc/ssh/ssh_host_ed25519_key"];
    age.rekey = fpLib.mkAgenixRekey {
      inherit (config.fireproof) hostname;
      store = ".rekey";
    };
  };
in {
  flake.modules.nixos.secrets = secretsModule "nixos";
  # agenix-rekey auto-discovers darwinConfigurations, so the Mac rekeys like any nixos host.
  flake.modules.darwin.secrets = secretsModule "darwin";
}
