# Home-manager agenix-rekey base (always-on; folder secrets/ ∈ base.includes).
# Mirrors modules/secrets/secrets.nix on the home-manager side so user secrets
# decrypt during HM activation with no osConfig bridge: the rekey identity comes
# from the `hostname` FACT, and runtime decryption uses ~/.ssh/id_ed25519 — the
# same host key (root places it via the nixos `ssh-key` secret) but user-readable,
# which is what HM activation (run as the user) can read.
{
  flake.modules.homeManager.hm-secrets = {
    config,
    inputs,
    ...
  }: let
    inherit (config.fireproof) hostname;
    hostSecrets = ../../secrets/hosts + ("/" + hostname);
    publicKey = builtins.readFile (hostSecrets + "/id_ed25519.pub");
  in {
    imports = [
      inputs.agenix.homeManagerModules.default
      inputs.agenix-rekey.homeManagerModules.default
    ];

    age.identityPaths = ["${config.home.homeDirectory}/.ssh/id_ed25519"];
    age.rekey = {
      storageMode = "local";
      hostPubkey = publicKey;
      masterIdentities = [{identity = ../../secrets/yubikey-identity.pub;}];
      extraEncryptionPubkeys = [
        "age1pzrfw28f8qvsk9g8p2stundf4ph466jut0g6q47sse76zljtqy9q2w32zr" # Backup key (bitwarden)
      ];
      # Distinct from the nixos store (.rekey): `agenix rekey` cleans each node's
      # localStorageDir of files not belonging to that node, so the nixos and
      # home-manager nodes for one host MUST NOT share a dir or they delete each
      # other's secrets. Same hostPubkey, so the encrypted blobs are identical.
      localStorageDir = hostSecrets + /.rekey-hm;
      generatedSecretsDir = hostSecrets;
    };
  };
}
