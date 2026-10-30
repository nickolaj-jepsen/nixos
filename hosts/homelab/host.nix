{
  shared = {
    fireproof.hostname = "homelab";

    fireproof.dev.enable = true;
    # headless: skip the heavy editor layer and the second agent
    fireproof.neovim.full.enable = false;
    fireproof.dev.pi.enable = true;
    fireproof.homelab.enable = true;
    fireproof.networkd.enable = true;
  };

  # Same headless trim for copilot, which has no fireproof toggle of its own.
  homeManager = {lib, ...}: {
    programs.github-copilot-cli.enable = lib.mkForce false;
  };
}
