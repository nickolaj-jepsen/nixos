# Home-manager agenix-rekey base (always-on; folder secrets/ ∈ base.includes).
# Mirrors the nixos secrets half on the home-manager side so user secrets
# decrypt during HM activation with no osConfig bridge: the rekey identity comes
# from the `hostname` FACT, and runtime decryption uses ~/.ssh/id_ed25519 — the
# same host key (root places it via the nixos `ssh-key` secret) but user-readable,
# which is what HM activation (run as the user) can read.
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

    # Runtime decryption uses ~/.ssh/id_ed25519 (the host key, placed there
    # user-readable by the nixos `ssh-key` secret) so HM activation — run as the
    # user — can read it. The `.rekey-hm` store keeps this node's blobs from being
    # cleaned by the nixos node's rekey; see fpLib.mkAgenixRekey.
    age.identityPaths = ["${config.home.homeDirectory}/.ssh/id_ed25519"];
    age.rekey = fpLib.mkAgenixRekey {
      inherit (config.fireproof) hostname;
      store = ".rekey-hm";
    };
  };
}
