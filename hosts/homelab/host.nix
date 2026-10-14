{
  shared = {
    fireproof.hostname = "homelab";

    fireproof.dev.enable = true;
    # headless: skip the heavy editor/agent layers
    fireproof.neovim.full.enable = false;
    fireproof.dev.pi.enable = false;
    fireproof.homelab.enable = true;
    fireproof.networkd.enable = true;
  };

  # Same headless trim for copilot, which has no fireproof toggle of its own.
  homeManager = {lib, ...}: {
    programs.github-copilot-cli.enable = lib.mkForce false;
  };
}
