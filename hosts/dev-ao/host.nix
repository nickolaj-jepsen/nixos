# dev-ao — the work dev server (dev.ao), a headless home-manager-only host and
# the standalone-HM portability guard (checks.dev-ao-home builds it). Not
# deployed yet; on deploy the age.identityPaths key must be provisioned
# out-of-band, since a home host has no root eval to place it.
{
  class = "home";

  # Headless: CLI tooling only — no desktop/gui-* toggles, so nothing pulls a GUI.
  shared = {
    fireproof.hostname = "dev-ao";
    fireproof.username = "nij";

    fireproof.dev.enable = true;
    fireproof.dev.clickhouse.enable = false; # headless server: no need for the clickhouse client
    # Work-owned server gets no personal tokens.
    fireproof.dev.pi.enable = false;
    fireproof.dev.opencode.enable = false;
    fireproof.dev.mcp.homelab.enable = false;
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
