# HM secrets decrypt during activation (run as user) with no osConfig bridge: rekey identity from the `hostname` fact.
{
  flake.modules.homeManager.hm-secrets = {
    config,
    inputs,
    fpLib,
    ...
  }: {
    imports = [
      inputs.agenix.homeManagerModules.default
      inputs.agenix-rekey.homeManagerModules.default
    ];

    # id_ed25519 is the host key, placed user-readable by the nixos `ssh-key` secret, so user-run HM activation can read it.
    age.identityPaths = ["${config.home.homeDirectory}/.ssh/id_ed25519"];
    age.rekey = fpLib.mkAgenixRekey {
      inherit (config.fireproof) hostname;
      store = ".rekey-hm"; # separate store: nixos node's rekey deletes blobs it doesn't own
    };
  };
}
