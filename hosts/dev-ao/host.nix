# dev-ao — the work dev server (dev.ao), a headless home-manager-only host.
# class = "home" routes it through buildHome (standalone home-manager, no NixOS
# eval) into flake.homeConfigurations.dev-ao, which home-check.nix builds in
# `just check` as the standalone-HM portability guard. Not deployed yet; on
# deploy the runtime decrypt identity (~/.ssh/id_ed25519) must be provisioned
# out-of-band, since a home host has no root eval to place it.
{
  class = "home";

  # Headless: CLI tooling only — no desktop/gui-* toggles, so nothing pulls a GUI.
  shared = {
    fireproof.hostname = "dev-ao";
    fireproof.username = "nij";

    fireproof.dev.enable = true;
    fireproof.work.enable = true;
    fireproof.claude-code.work.enable = true;
  };

  # The dev server decrypts HM secrets with its existing RSA key at ~/.ssh/id_rsa,
  # not the ~/.ssh/id_ed25519 the always-on hm-secrets leaf assumes.
  homeManager = {
    config,
    lib,
    ...
  }: {
    age.identityPaths = lib.mkForce ["${config.home.homeDirectory}/.ssh/id_rsa"];
  };
}
